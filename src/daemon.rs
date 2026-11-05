use std::{
    fs,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    sync::Arc,
    time::Duration,
};

use anyhow::{Context, Result, bail};
use librqbit::{
    AddTorrent, AddTorrentOptions, AddTorrentResponse, DhtSessionConfig, ListenerOptions,
    ManagedTorrent, Session, SessionOptions, SessionPersistenceConfig, TorrentStatsState,
    api::TorrentIdOrHash,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
};

use crate::{
    paths::{AppPaths, create_private_dir},
    protocol::{MAX_REQUEST_BYTES, Request, Response, TorrentSummary},
};

pub async fn run(paths: AppPaths) -> Result<()> {
    paths.prepare()?;
    create_private_dir(&paths.session)?;
    let config = paths.load_config()?;
    let download_dir = config.ensure_download_dir()?;
    let (listener, _guard) = bind_control_socket(&paths)?;

    let session = Session::new_with_opts(
        download_dir,
        SessionOptions {
            dht: Some(DhtSessionConfig {
                persistence: None,
                ..Default::default()
            }),
            fastresume: true,
            persistence: Some(SessionPersistenceConfig::Json {
                folder: Some(paths.session.clone()),
            }),
            listen: Some(ListenerOptions::default()),
            disable_local_service_discovery: true,
            client_name_and_version: Some(format!("SnagTorrent {}", env!("CARGO_PKG_VERSION"))),
            ..Default::default()
        },
    )
    .await
    .context("could not start the BitTorrent session")?;

    tracing::info!("SnagTorrent daemon started");
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _)) => {
                        let session = session.clone();
                        tokio::spawn(async move {
                            if let Err(error) = handle_connection(stream, session).await {
                                tracing::warn!("local client error: {error:#}");
                            }
                        });
                    }
                    Err(error) => tracing::warn!("could not accept local client: {error}"),
                }
            }
            _ = session.cancellation_token().cancelled() => break,
            _ = tokio::signal::ctrl_c() => break,
            _ = sigterm.recv() => break,
        }
    }

    session.cancellation_token().cancel();
    tracing::info!("SnagTorrent daemon stopped");
    Ok(())
}

async fn handle_connection(stream: UnixStream, session: Arc<Session>) -> Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut line = String::new();
    let read = tokio::time::timeout(Duration::from_secs(10), async {
        let bytes = (&mut reader)
            .take(MAX_REQUEST_BYTES + 1)
            .read_line(&mut line)
            .await?;
        anyhow::Ok(bytes)
    })
    .await
    .context("timed out reading local request")??;

    if read == 0 {
        return Ok(());
    }
    if read as u64 > MAX_REQUEST_BYTES || !line.ends_with('\n') {
        writer
            .write_all(&response_bytes(Response::error("request is too large")))
            .await?;
        return Ok(());
    }

    let mut shutdown = false;
    let response = match serde_json::from_str::<Request>(&line) {
        Ok(request) => {
            shutdown = matches!(&request, Request::Shutdown);
            handle_request(request, session.clone()).await
        }
        Err(error) => Response::error(format!("invalid request: {error}")),
    };
    writer.write_all(&response_bytes(response)).await?;
    writer.shutdown().await?;
    if shutdown {
        session.cancellation_token().cancel();
    }
    Ok(())
}

async fn handle_request(request: Request, session: Arc<Session>) -> Response {
    match request {
        Request::Ping => Response::message("running"),
        Request::List => {
            let mut torrents = session.with_torrents(|items| {
                items
                    .map(|(_, handle)| summarize(handle))
                    .collect::<Vec<_>>()
            });
            torrents.sort_by_key(|torrent| torrent.id);
            Response::list(torrents)
        }
        Request::Add {
            source,
            paused,
            initial_peers,
        } => {
            let add = match AddTorrent::from_cli_argument(&source) {
                Ok(add) => add,
                Err(error) => return Response::error(format!("could not read torrent: {error:#}")),
            };
            let options = AddTorrentOptions {
                paused,
                overwrite: true,
                initial_peers: if initial_peers.is_empty() {
                    None
                } else {
                    Some(initial_peers)
                },
                ..Default::default()
            };
            let added = match tokio::time::timeout(
                Duration::from_secs(120),
                session.add_torrent(add, Some(options)),
            )
            .await
            {
                Ok(Ok(added)) => added,
                Ok(Err(error)) => {
                    return Response::error(format!("could not add torrent: {error:#}"));
                }
                Err(_) => {
                    return Response::error(
                        "could not resolve torrent metadata within 120 seconds; try again when peers are available",
                    );
                }
            };
            match added {
                AddTorrentResponse::Added(id, handle) => {
                    Response::torrent(format!("Added {id}"), summarize(&handle))
                }
                AddTorrentResponse::AlreadyManaged(id, handle) => {
                    Response::torrent(format!("Already added as {id}"), summarize(&handle))
                }
                AddTorrentResponse::ListOnly(_) => Response::error("unexpected list-only response"),
            }
        }
        Request::Pause { id } => match session.get(TorrentIdOrHash::Id(id)) {
            Some(handle) => match session.pause(&handle).await {
                Ok(()) => Response::message(format!("Paused {id}")),
                Err(error) => Response::error(format!("could not pause {id}: {error:#}")),
            },
            None => Response::error(format!("no torrent with ID {id}")),
        },
        Request::Resume { id } => match session.get(TorrentIdOrHash::Id(id)) {
            Some(handle) => match session.unpause(&handle).await {
                Ok(()) => Response::message(format!("Resumed {id}")),
                Err(error) => Response::error(format!("could not resume {id}: {error:#}")),
            },
            None => Response::error(format!("no torrent with ID {id}")),
        },
        Request::Remove { id, delete_files } => {
            match session.delete(TorrentIdOrHash::Id(id), delete_files).await {
                Ok(()) if delete_files => {
                    Response::message(format!("Removed {id} and deleted its files"))
                }
                Ok(()) => Response::message(format!("Removed {id}; files kept")),
                Err(error) => Response::error(format!("could not remove {id}: {error:#}")),
            }
        }
        Request::Shutdown => Response::message("SnagTorrent stopped"),
    }
}

fn summarize(handle: &Arc<ManagedTorrent>) -> TorrentSummary {
    let stats = handle.stats();
    let state = match &stats.state {
        TorrentStatsState::Initializing { paused: true } => "paused",
        TorrentStatsState::Live if stats.finished => "seeding",
        TorrentStatsState::Initializing { .. } => "initializing",
        TorrentStatsState::Live => "downloading",
        TorrentStatsState::Paused => "paused",
        TorrentStatsState::Error => "error",
    }
    .to_owned();
    let (download_speed, upload_speed) = stats
        .live
        .as_ref()
        .map(|live| (live.download_speed.as_bytes(), live.upload_speed.as_bytes()))
        .unwrap_or_default();
    TorrentSummary {
        id: handle.id(),
        name: handle
            .name()
            .unwrap_or_else(|| handle.info_hash().as_string()),
        info_hash: handle.info_hash().as_string(),
        state,
        progress_bytes: stats.progress_bytes,
        total_bytes: stats.total_bytes,
        download_speed,
        upload_speed,
        output_folder: handle.output_folder().to_string_lossy().into_owned(),
        error: stats.error,
    }
}

fn response_bytes(response: Response) -> Vec<u8> {
    match serde_json::to_vec(&response) {
        Ok(bytes) => bytes,
        Err(error) => format!("{{\"error\":\"could not encode response: {error}\"}}").into_bytes(),
    }
}

fn bind_control_socket(paths: &AppPaths) -> Result<(UnixListener, SocketGuard)> {
    let listener = match UnixListener::bind(&paths.socket) {
        Ok(listener) => listener,
        Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => {
            if std::os::unix::net::UnixStream::connect(&paths.socket).is_ok() {
                bail!("SnagTorrent is already running");
            }
            fs::remove_file(&paths.socket).context("could not remove stale control socket")?;
            UnixListener::bind(&paths.socket).context("could not bind control socket")?
        }
        Err(error) => return Err(error).context("could not bind control socket"),
    };
    fs::set_permissions(&paths.socket, fs::Permissions::from_mode(0o600))?;
    let mut pid_file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(paths.state_dir.join("daemon.pid"))?;
    std::io::Write::write_all(
        &mut pid_file,
        format!("{}\n", std::process::id()).as_bytes(),
    )?;
    Ok((listener, SocketGuard(paths.socket.clone())))
}

struct SocketGuard(std::path::PathBuf);

impl Drop for SocketGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
