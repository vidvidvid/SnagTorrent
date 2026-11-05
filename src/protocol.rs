use std::net::SocketAddr;

use serde::{Deserialize, Serialize};

pub const MAX_REQUEST_BYTES: u64 = 128 * 1024;
pub const MAX_RESPONSE_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
pub enum Request {
    Ping,
    Add {
        source: String,
        paused: bool,
        initial_peers: Vec<SocketAddr>,
        /// Download only these file indices (see `Inspect`); `None` means every file.
        #[serde(default)]
        only_files: Option<Vec<usize>>,
    },
    /// Resolve a source's metadata without adding it, so a client can show the
    /// file list first. A following `Add` of the same source reuses the metadata.
    Inspect {
        source: String,
    },
    List,
    Pause {
        id: usize,
    },
    Resume {
        id: usize,
    },
    Remove {
        id: usize,
        delete_files: bool,
    },
    /// Download only these files (indices into `TorrentSummary::files`).
    SetFiles {
        id: usize,
        files: Vec<usize>,
    },
    /// Daemon version, folders, and settings.
    Status,
    /// Change settings; unset fields keep their value. Replies with the new status.
    Configure {
        #[serde(default)]
        pause_when_done: Option<bool>,
    },
    /// A local URL that streams one file while it downloads (for media players).
    StreamUrl {
        id: usize,
        file: usize,
    },
    Shutdown,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Response {
    pub error: Option<String>,
    pub message: Option<String>,
    pub torrents: Vec<TorrentSummary>,
    /// Set only for `Inspect`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<TorrentPreview>,
    /// Set for `Status` and `Configure`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<DaemonStatus>,
    /// Set for `StreamUrl`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream_url: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DaemonStatus {
    pub version: String,
    pub download_dir: String,
    /// Pause a torrent once it finishes instead of seeding it.
    pub pause_when_done: bool,
    /// Local port of the streaming server (127.0.0.1 only).
    pub stream_port: u16,
}

/// Metadata of a torrent that has not been added yet.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TorrentPreview {
    pub name: String,
    pub info_hash: String,
    pub total_bytes: u64,
    pub files: Vec<FileSummary>,
}

impl Response {
    pub fn message(message: impl Into<String>) -> Self {
        Self {
            error: None,
            message: Some(message.into()),
            torrents: Vec::new(),
            preview: None,
            status: None,
            stream_url: None,
        }
    }

    pub fn torrent(message: impl Into<String>, torrent: TorrentSummary) -> Self {
        Self {
            error: None,
            message: Some(message.into()),
            torrents: vec![torrent],
            preview: None,
            status: None,
            stream_url: None,
        }
    }

    pub fn list(torrents: Vec<TorrentSummary>) -> Self {
        Self {
            error: None,
            message: None,
            torrents,
            preview: None,
            status: None,
            stream_url: None,
        }
    }

    pub fn preview(preview: TorrentPreview) -> Self {
        Self {
            preview: Some(preview),
            ..Self::list(Vec::new())
        }
    }

    pub fn status(status: DaemonStatus) -> Self {
        Self {
            status: Some(status),
            ..Self::list(Vec::new())
        }
    }

    pub fn stream_url(url: String) -> Self {
        Self {
            stream_url: Some(url),
            ..Self::list(Vec::new())
        }
    }

    pub fn error(error: impl Into<String>) -> Self {
        Self {
            error: Some(error.into()),
            message: None,
            torrents: Vec::new(),
            preview: None,
            status: None,
            stream_url: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TorrentSummary {
    pub id: usize,
    pub name: String,
    pub info_hash: String,
    pub state: String,
    pub progress_bytes: u64,
    pub total_bytes: u64,
    pub download_speed: u64,
    pub upload_speed: u64,
    pub output_folder: String,
    pub error: Option<String>,
    #[serde(default)]
    pub uploaded_bytes: u64,
    /// Connected peers that already have the whole torrent.
    #[serde(default)]
    pub seeders: u64,
    /// Connected peers that are still downloading.
    #[serde(default)]
    pub leechers: u64,
    /// Seconds until the download completes, when it is downloading at a measurable rate.
    #[serde(default)]
    pub eta_seconds: Option<u64>,
    /// Files in the torrent, in torrent order; empty until metadata is resolved.
    #[serde(default)]
    pub files: Vec<FileSummary>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FileSummary {
    /// Path relative to `output_folder`.
    pub path: String,
    pub length: u64,
    pub progress_bytes: u64,
    /// Whether this file is wanted; unselected files are skipped.
    #[serde(default = "default_true")]
    pub selected: bool,
}

fn default_true() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_add_request_without_only_files_still_parses() {
        let request: Request = serde_json::from_str(
            r#"{"Add":{"source":"magnet:?x","paused":false,"initial_peers":[]}}"#,
        )
        .unwrap();
        match request {
            Request::Add { only_files, .. } => assert!(only_files.is_none()),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn configure_fields_are_optional() {
        let request: Request = serde_json::from_str(r#"{"Configure":{}}"#).unwrap();
        assert!(matches!(
            request,
            Request::Configure {
                pause_when_done: None
            }
        ));
    }

    #[test]
    fn unit_requests_are_plain_strings() {
        assert_eq!(serde_json::to_string(&Request::List).unwrap(), r#""List""#);
        assert_eq!(
            serde_json::to_string(&Request::Status).unwrap(),
            r#""Status""#
        );
    }

    #[test]
    fn list_response_omits_unset_extras() {
        let json = serde_json::to_value(Response::list(Vec::new())).unwrap();
        assert!(json.get("preview").is_none());
        assert!(json.get("status").is_none());
        assert!(json.get("stream_url").is_none());
    }

    #[test]
    fn summary_from_older_daemon_fills_defaults() {
        let summary: TorrentSummary = serde_json::from_str(
            r#"{"id":1,"name":"n","info_hash":"h","state":"paused","progress_bytes":0,
                "total_bytes":10,"download_speed":0,"upload_speed":0,"output_folder":"/","error":null}"#,
        )
        .unwrap();
        assert_eq!(summary.seeders, 0);
        assert!(summary.eta_seconds.is_none());
        assert!(summary.files.is_empty());
    }

    #[test]
    fn file_selected_defaults_to_true() {
        let file: FileSummary =
            serde_json::from_str(r#"{"path":"a","length":1,"progress_bytes":0}"#).unwrap();
        assert!(file.selected);
    }
}
