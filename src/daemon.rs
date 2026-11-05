use std::{
    collections::{HashMap, HashSet},
    fs,
    net::SocketAddr,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{Context, Result, bail};
use librqbit::{
    AddTorrent, AddTorrentOptions, AddTorrentResponse, DhtSessionConfig, ListenerOptions, Magnet,
    ManagedTorrent, Session, SessionOptions, SessionPersistenceConfig, TorrentStatsState,
    api::TorrentIdOrHash,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
};

use crate::{
    paths::{AppPaths, create_private_dir},
    protocol::{FileSummary, MAX_REQUEST_BYTES, Request, Response, TorrentPreview, TorrentSummary},
};

/// Metadata kept from an `Inspect` so the following `Add` does not fetch it again.
struct Inspected {
    torrent_bytes: bytes::Bytes,
    seen_peers: Vec<SocketAddr>,
}

const MAX_INSPECTED: usize = 32;

struct Daemon {
    session: Arc<Session>,
    inspected: Mutex<HashMap<String, Inspected>>,
}

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

    let daemon = Arc::new(Daemon {
        session: session.clone(),
        inspected: Mutex::new(HashMap::new()),
    });
    tracing::info!("SnagTorrent daemon started");
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _)) => {
                        let daemon = daemon.clone();
                        tokio::spawn(async move {
                            if let Err(error) = handle_connection(stream, daemon).await {
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

async fn handle_connection(stream: UnixStream, daemon: Arc<Daemon>) -> Result<()> {
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
            handle_request(request, &daemon).await
        }
        Err(error) => Response::error(format!("invalid request: {error}")),
    };
    writer.write_all(&response_bytes(response)).await?;
    writer.shutdown().await?;
    if shutdown {
        daemon.session.cancellation_token().cancel();
    }
    Ok(())
}

async fn handle_request(request: Request, daemon: &Daemon) -> Response {
    let session = &daemon.session;
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
            mut initial_peers,
            only_files,
        } => {
            let inspected = daemon.inspected.lock().unwrap().remove(&source);
            let (add, trackers) = match inspected {
                Some(inspected) => {
                    initial_peers.extend(inspected.seen_peers);
                    (
                        AddTorrent::TorrentFileBytes(inspected.torrent_bytes),
                        magnet_trackers(&source),
                    )
                }
                None => match AddTorrent::from_cli_argument(&source) {
                    Ok(add) => (add, None),
                    Err(error) => return Response::error(format!("could not read torrent: {error:#}")),
                },
            };
            initial_peers.sort_unstable();
            initial_peers.dedup();
            let options = AddTorrentOptions {
                paused,
                overwrite: true,
                only_files,
                trackers,
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
        Request::Inspect { source } => {
            let add = match AddTorrent::from_cli_argument(&source) {
                Ok(add) => add,
                Err(error) => return Response::error(format!("could not read torrent: {error:#}")),
            };
            let options = AddTorrentOptions {
                list_only: true,
                ..Default::default()
            };
            let listed = match tokio::time::timeout(
                Duration::from_secs(120),
                session.add_torrent(add, Some(options)),
            )
            .await
            {
                Ok(Ok(AddTorrentResponse::ListOnly(listed))) => listed,
                Ok(Ok(AddTorrentResponse::Added(_, handle)))
                | Ok(Ok(AddTorrentResponse::AlreadyManaged(_, handle))) => {
                    return Response::torrent("Already added", summarize(&handle));
                }
                Ok(Err(error)) => {
                    return Response::error(format!("could not read torrent: {error:#}"));
                }
                Err(_) => {
                    return Response::error(
                        "could not resolve torrent metadata within 120 seconds; try again when peers are available",
                    );
                }
            };
            let files = listed
                .info
                .iter_file_details()
                .map(|file| FileSummary {
                    path: file.filename.to_pathbuf().to_string_lossy().into_owned(),
                    length: file.len,
                    progress_bytes: 0,
                    selected: true,
                })
                .collect::<Vec<_>>();
            let preview = TorrentPreview {
                name: listed
                    .info
                    .name()
                    .map(|name| name.into_owned())
                    .or_else(|| Magnet::parse(&source).ok().and_then(|magnet| magnet.name))
                    .unwrap_or_else(|| listed.info_hash.as_string()),
                info_hash: listed.info_hash.as_string(),
                total_bytes: files.iter().map(|file| file.length).sum(),
                files,
            };
            let mut inspected = daemon.inspected.lock().unwrap();
            if inspected.len() >= MAX_INSPECTED {
                inspected.clear();
            }
            inspected.insert(
                source,
                Inspected {
                    torrent_bytes: listed.torrent_bytes,
                    seen_peers: listed.seen_peers,
                },
            );
            Response::preview(preview)
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
                Ok(()) => {
                    resume_after_check(session.clone(), handle);
                    Response::message(format!("Resumed {id}"))
                }
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
        Request::SetFiles { id, files } => match session.get(TorrentIdOrHash::Id(id)) {
            Some(handle) => {
                let count = handle
                    .with_metadata(|metadata| metadata.file_infos.len())
                    .unwrap_or(0);
                if files.is_empty() {
                    return Response::error("select at least one file");
                }
                if files.iter().any(|&index| index >= count) {
                    return Response::error(format!("file index out of range; {id} has {count} files"));
                }
                let selected = files.iter().copied().collect::<HashSet<usize>>();
                match session.update_only_files(&handle, &selected).await {
                    Ok(()) => Response::torrent(
                        format!("Selected {} of {count} files for {id}", selected.len()),
                        summarize(&handle),
                    ),
                    Err(error) => Response::error(format!("could not select files for {id}: {error:#}")),
                }
            }
            None => Response::error(format!("no torrent with ID {id}")),
        },
        Request::Shutdown => Response::message("SnagTorrent stopped"),
    }
}

/// Trackers from a magnet link, so a torrent added from cached metadata keeps them.
fn magnet_trackers(source: &str) -> Option<Vec<String>> {
    Magnet::parse(source)
        .ok()
        .map(|magnet| magnet.trackers)
        .filter(|trackers| !trackers.is_empty())
}

/// rqbit drops an unpause that arrives while the torrent's initial hash check is
/// still running, leaving it paused once the check finishes. Watch for that and
/// unpause again.
fn resume_after_check(session: Arc<Session>, handle: Arc<ManagedTorrent>) {
    tokio::spawn(async move {
        for _ in 0..(6 * 60 * 60 * 4) {
            tokio::time::sleep(Duration::from_millis(250)).await;
            match handle.stats().state {
                TorrentStatsState::Initializing { .. } => continue,
                TorrentStatsState::Paused => {
                    if let Err(error) = session.unpause(&handle).await {
                        tracing::warn!("could not resume {} after check: {error:#}", handle.id());
                    }
                }
                _ => {}
            }
            break;
        }
    });
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
    let (seeders, leechers) = stats
        .live
        .as_ref()
        .map(|live| {
            let peers = &live.snapshot.peer_stats;
            let seeders = u64::from(peers.live_seeders);
            (seeders, u64::from(peers.live).saturating_sub(seeders))
        })
        .unwrap_or_default();
    let remaining = stats.total_bytes.saturating_sub(stats.progress_bytes);
    let eta_seconds = if state == "downloading" && download_speed > 0 && remaining > 0 {
        Some(remaining.div_ceil(download_speed))
    } else {
        None
    };
    let only_files = handle.only_files();
    let files = handle
        .with_metadata(|metadata| {
            metadata
                .file_infos
                .iter()
                .enumerate()
                .map(|(index, file)| FileSummary {
                    path: file.relative_filename.to_string_lossy().into_owned(),
                    length: file.len,
                    progress_bytes: stats.file_progress.get(index).copied().unwrap_or(0),
                    selected: only_files
                        .as_ref()
                        .is_none_or(|only| only.contains(&index)),
                })
                .collect::<Vec<_>>()
        })
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
        uploaded_bytes: stats.uploaded_bytes,
        seeders,
        leechers,
        eta_seconds,
        files,
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
