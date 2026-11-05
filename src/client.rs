use std::{
    os::unix::process::CommandExt,
    path::PathBuf,
    process::{Command, Stdio},
    time::Duration,
};

use anyhow::{Context, Result, bail};
use librqbit::Magnet;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
};

use crate::{
    paths::AppPaths,
    protocol::{MAX_RESPONSE_BYTES, Request, Response},
};

pub async fn ensure_running(paths: &AppPaths) -> Result<()> {
    if call_once(paths, &Request::Ping, Duration::from_secs(2))
        .await
        .is_ok()
    {
        return Ok(());
    }

    paths.prepare()?;
    let log = paths.open_log()?;
    let stderr = log.try_clone()?;
    let executable = std::env::current_exe().context("could not locate the snag executable")?;
    let mut command = Command::new(executable);
    command
        .arg("serve")
        .env("SNAG_HOME", &paths.state_dir)
        .current_dir(&paths.state_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(stderr));
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command
        .spawn()
        .context("could not start the SnagTorrent daemon")?;

    for _ in 0..200 {
        if call_once(paths, &Request::Ping, Duration::from_millis(250))
            .await
            .is_ok()
        {
            return Ok(());
        }
        if let Some(status) = child.try_wait()? {
            bail!(
                "the daemon exited during startup ({status}); check {}",
                paths.log.display()
            );
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    bail!(
        "the daemon did not become ready; check {}",
        paths.log.display()
    )
}

pub async fn call(paths: &AppPaths, request: Request) -> Result<Response> {
    ensure_running(paths).await?;
    let timeout = match request {
        Request::Add { .. } => Duration::from_secs(130),
        _ => Duration::from_secs(15),
    };
    call_once(paths, &request, timeout).await
}

pub async fn call_without_start(paths: &AppPaths, request: Request) -> Result<Response> {
    call_once(paths, &request, Duration::from_secs(15)).await
}

async fn call_once(paths: &AppPaths, request: &Request, timeout: Duration) -> Result<Response> {
    tokio::time::timeout(timeout, exchange(paths, request))
        .await
        .context("timed out talking to the SnagTorrent daemon")?
}

async fn exchange(paths: &AppPaths, request: &Request) -> Result<Response> {
    let mut stream = UnixStream::connect(&paths.socket)
        .await
        .context("SnagTorrent is not running")?;
    let mut encoded = serde_json::to_vec(request)?;
    encoded.push(b'\n');
    stream.write_all(&encoded).await?;
    stream.shutdown().await?;

    let mut bytes = Vec::new();
    let read = stream
        .take(MAX_RESPONSE_BYTES + 1)
        .read_to_end(&mut bytes)
        .await
        .context("could not read the daemon response")?;
    if read as u64 > MAX_RESPONSE_BYTES {
        bail!("daemon response is too large");
    }
    let response: Response =
        serde_json::from_slice(&bytes).context("daemon returned an invalid response")?;
    if let Some(error) = response.error.as_ref() {
        bail!(error.clone());
    }
    Ok(response)
}

pub fn normalize_source(input: &str) -> Result<String> {
    if input.is_empty() || input.chars().any(char::is_control) {
        bail!("torrent source is empty or contains control characters");
    }
    if input.len() > 64 * 1024 {
        bail!("torrent source is too long");
    }
    if input.starts_with("magnet:")
        || (input.len() == 40 && input.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        Magnet::parse(input).context("invalid magnet link or info hash")?;
        return Ok(input.to_owned());
    }
    if input.starts_with("https://") || input.starts_with("http://") {
        return Ok(input.to_owned());
    }
    if input.contains("://") {
        bail!("only magnet links, HTTP(S) torrent URLs, and local .torrent files are supported");
    }
    let path = PathBuf::from(input)
        .canonicalize()
        .with_context(|| format!("could not find torrent file {input}"))?;
    if !path.is_file() {
        bail!("torrent source is not a file: {}", path.display());
    }
    path.to_str()
        .map(str::to_owned)
        .context("torrent file path is not valid UTF-8")
}
