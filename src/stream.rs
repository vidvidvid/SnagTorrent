//! A minimal HTTP/1.1 server on 127.0.0.1 that streams one torrent file at a
//! time, with `Range` support so media players can seek. Every URL carries a
//! random token that only local socket clients can learn.

use std::{io::Read, sync::Arc, time::Duration};

use anyhow::{Context, Result, bail};
use librqbit::{Session, api::TorrentIdOrHash};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncSeekExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
};

pub struct StreamServer {
    pub port: u16,
    pub token: String,
}

impl StreamServer {
    pub async fn start(session: Arc<Session>) -> Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .context("could not bind the local streaming port")?;
        let port = listener.local_addr()?.port();
        let token = random_token()?;
        let accept_token = token.clone();
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((stream, _)) => {
                        let session = session.clone();
                        let token = accept_token.clone();
                        tokio::spawn(async move {
                            if let Err(error) = handle(stream, session, &token).await {
                                tracing::debug!("stream connection ended: {error:#}");
                            }
                        });
                    }
                    Err(error) => {
                        tracing::warn!("could not accept stream client: {error}");
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                }
            }
        });
        Ok(Self { port, token })
    }

    pub fn url(&self, id: usize, file: usize, name: &str) -> String {
        format!(
            "http://127.0.0.1:{}/{}/{id}/{file}/{}",
            self.port,
            self.token,
            url_safe_name(name)
        )
    }
}

fn random_token() -> Result<String> {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .context("could not read random bytes")?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Keeps the extension so players can pick a decoder; everything else becomes `_`.
pub fn url_safe_name(name: &str) -> String {
    let safe = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect::<String>();
    if safe.is_empty() {
        "file".to_owned()
    } else {
        safe
    }
}

pub fn content_type(name: &str) -> &'static str {
    let extension = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match extension.as_str() {
        "mp4" | "m4v" => "video/mp4",
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        "avi" => "video/x-msvideo",
        "wmv" => "video/x-ms-wmv",
        "flv" => "video/x-flv",
        "mpg" | "mpeg" => "video/mpeg",
        "ts" | "m2ts" => "video/mp2t",
        "ogv" => "video/ogg",
        "3gp" => "video/3gpp",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "flac" => "audio/flac",
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        _ => "application/octet-stream",
    }
}

/// Parses `bytes=start-end` (inclusive), `bytes=start-`, or `bytes=-suffix`.
/// Returns `None` for a header this server cannot satisfy.
pub fn parse_range(header: &str, len: u64) -> Option<(u64, u64)> {
    let spec = header.trim().strip_prefix("bytes=")?;
    if spec.contains(',') || len == 0 {
        return None;
    }
    let (start, end) = spec.split_once('-')?;
    let (start, end) = (start.trim(), end.trim());
    if start.is_empty() {
        let suffix: u64 = end.parse().ok()?;
        if suffix == 0 {
            return None;
        }
        return Some((len.saturating_sub(suffix), len - 1));
    }
    let start: u64 = start.parse().ok()?;
    if start >= len {
        return None;
    }
    let end = if end.is_empty() {
        len - 1
    } else {
        end.parse::<u64>().ok()?.min(len - 1)
    };
    (start <= end).then_some((start, end))
}

async fn handle(stream: TcpStream, session: Arc<Session>, token: &str) -> Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader.take(16 * 1024));
    let mut request_line = String::new();
    let mut range = None;
    tokio::time::timeout(Duration::from_secs(10), async {
        reader.read_line(&mut request_line).await?;
        let mut line = String::new();
        loop {
            line.clear();
            if reader.read_line(&mut line).await? == 0 || line == "\r\n" || line == "\n" {
                break;
            }
            if let Some((name, value)) = line.split_once(':')
                && name.eq_ignore_ascii_case("range")
            {
                range = Some(value.trim().to_owned());
            }
        }
        anyhow::Ok(())
    })
    .await
    .context("timed out reading stream request")??;

    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");
    if !matches!(method, "GET" | "HEAD") {
        return respond_text(&mut writer, "405 Method Not Allowed", "only GET and HEAD").await;
    }
    let segments = path.trim_start_matches('/').split('/').collect::<Vec<_>>();
    let (id, file, name) = match segments.as_slice() {
        [given, id, file, name] if *given == token => (
            id.parse::<usize>().ok(),
            file.parse::<usize>().ok(),
            (*name).to_owned(),
        ),
        _ => return respond_text(&mut writer, "404 Not Found", "not found").await,
    };
    let (Some(id), Some(file)) = (id, file) else {
        return respond_text(&mut writer, "404 Not Found", "not found").await;
    };
    let Some(handle) = session.get(TorrentIdOrHash::Id(id)) else {
        return respond_text(&mut writer, "404 Not Found", "no such torrent").await;
    };
    let mut file_stream = match handle.stream(file).await {
        Ok(stream) => stream,
        Err(error) => {
            return respond_text(
                &mut writer,
                "503 Service Unavailable",
                &format!("cannot stream yet: {error:#}"),
            )
            .await;
        }
    };
    let len = file_stream.len();
    let content_type = content_type(&name);

    let (status, start, end) = match range.as_deref() {
        None => ("200 OK", 0, len.saturating_sub(1)),
        Some(header) => match parse_range(header, len) {
            Some((start, end)) => ("206 Partial Content", start, end),
            None => {
                let head = format!(
                    "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{len}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
                writer.write_all(head.as_bytes()).await?;
                return Ok(());
            }
        },
    };
    let count = if len == 0 { 0 } else { end - start + 1 };
    let mut head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {count}\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"
    );
    if status.starts_with("206") {
        head.push_str(&format!("Content-Range: bytes {start}-{end}/{len}\r\n"));
    }
    head.push_str("\r\n");
    writer.write_all(head.as_bytes()).await?;
    if method == "HEAD" || count == 0 {
        return Ok(());
    }
    file_stream.seek(std::io::SeekFrom::Start(start)).await?;
    let mut limited = file_stream.take(count);
    match tokio::io::copy(&mut limited, &mut writer).await {
        Ok(_) => Ok(()),
        // Players close connections mid-stream when seeking; that is not an error.
        Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => Ok(()),
        Err(error) => bail!(error),
    }
}

async fn respond_text(
    writer: &mut tokio::net::tcp::OwnedWriteHalf,
    status: &str,
    body: &str,
) -> Result<()> {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    writer.write_all(head.as_bytes()).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges() {
        assert_eq!(parse_range("bytes=0-99", 1000), Some((0, 99)));
        assert_eq!(parse_range("bytes=500-", 1000), Some((500, 999)));
        assert_eq!(parse_range("bytes=-100", 1000), Some((900, 999)));
        assert_eq!(parse_range("bytes=0-5000", 1000), Some((0, 999)));
        assert_eq!(parse_range("bytes=1000-", 1000), None);
        assert_eq!(parse_range("bytes=5-2", 1000), None);
        assert_eq!(parse_range("bytes=0-1,5-6", 1000), None);
        assert_eq!(parse_range("items=0-1", 1000), None);
        assert_eq!(parse_range("bytes=-0", 1000), None);
        assert_eq!(parse_range("bytes=0-", 0), None);
    }

    #[test]
    fn names_and_types() {
        assert_eq!(url_safe_name("Big Buck Bunny.mp4"), "Big_Buck_Bunny.mp4");
        assert_eq!(url_safe_name("日本.mkv"), "__.mkv");
        assert_eq!(url_safe_name(""), "file");
        assert_eq!(content_type("x.MP4"), "video/mp4");
        assert_eq!(content_type("x.mkv"), "video/x-matroska");
        assert_eq!(content_type("x.iso"), "application/octet-stream");
    }
}
