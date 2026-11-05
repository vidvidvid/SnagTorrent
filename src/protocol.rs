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
    Shutdown,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Response {
    pub error: Option<String>,
    pub message: Option<String>,
    pub torrents: Vec<TorrentSummary>,
}

impl Response {
    pub fn message(message: impl Into<String>) -> Self {
        Self {
            error: None,
            message: Some(message.into()),
            torrents: Vec::new(),
        }
    }

    pub fn torrent(message: impl Into<String>, torrent: TorrentSummary) -> Self {
        Self {
            error: None,
            message: Some(message.into()),
            torrents: vec![torrent],
        }
    }

    pub fn list(torrents: Vec<TorrentSummary>) -> Self {
        Self {
            error: None,
            message: None,
            torrents,
        }
    }

    pub fn error(error: impl Into<String>) -> Self {
        Self {
            error: Some(error.into()),
            message: None,
            torrents: Vec::new(),
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
}
