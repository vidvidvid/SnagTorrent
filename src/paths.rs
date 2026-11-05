use std::{
    fs,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug)]
pub struct AppPaths {
    pub state_dir: PathBuf,
    pub socket: PathBuf,
    pub config: PathBuf,
    pub session: PathBuf,
    pub log: PathBuf,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    pub download_dir: PathBuf,
    /// Pause a torrent once it finishes instead of seeding it.
    #[serde(default = "default_pause_when_done")]
    pub pause_when_done: bool,
}

fn default_pause_when_done() -> bool {
    true
}

impl AppPaths {
    pub fn discover() -> Result<Self> {
        let state_dir = match std::env::var_os("SNAG_HOME") {
            Some(path) => PathBuf::from(path),
            None => default_state_dir()?,
        };
        Ok(Self {
            socket: state_dir.join("control.sock"),
            config: state_dir.join("config.json"),
            session: state_dir.join("session"),
            log: state_dir.join("daemon.log"),
            state_dir,
        })
    }

    pub fn prepare(&self) -> Result<()> {
        create_private_dir(&self.state_dir)?;
        if self.socket.as_os_str().len() > 96 {
            bail!(
                "state directory path is too long for a local socket: {}",
                self.state_dir.display()
            );
        }
        Ok(())
    }

    pub fn load_config(&self) -> Result<Config> {
        match fs::read(&self.config) {
            Ok(bytes) => serde_json::from_slice(&bytes).context("could not parse config.json"),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let home = home_dir()?;
                Ok(Config {
                    download_dir: home.join("Downloads").join("SnagTorrent"),
                    pause_when_done: default_pause_when_done(),
                })
            }
            Err(error) => Err(error).context("could not read config.json"),
        }
    }

    pub fn save_config(&self, config: &Config) -> Result<()> {
        self.prepare()?;
        let bytes = serde_json::to_vec_pretty(config)?;
        let temp = self.state_dir.join("config.json.tmp");
        let mut file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&temp)
            .context("could not write temporary config")?;
        std::io::Write::write_all(&mut file, &bytes)?;
        fs::set_permissions(&temp, fs::Permissions::from_mode(0o600))?;
        fs::rename(&temp, &self.config).context("could not save config.json")?;
        Ok(())
    }

    pub fn open_log(&self) -> Result<fs::File> {
        fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&self.log)
            .context("could not open daemon.log")
    }
}

impl Config {
    pub fn ensure_download_dir(&self) -> Result<PathBuf> {
        if self.download_dir.as_os_str().is_empty() {
            bail!("download directory cannot be empty");
        }
        if !self.download_dir.is_absolute() {
            bail!("download directory must be an absolute path");
        }
        let existed = self.download_dir.exists();
        fs::create_dir_all(&self.download_dir).with_context(|| {
            format!(
                "could not create download directory {}",
                self.download_dir.display()
            )
        })?;
        if !existed {
            fs::set_permissions(&self.download_dir, fs::Permissions::from_mode(0o700))?;
        }
        self.download_dir.canonicalize().context(
            "could not resolve download directory; check that it is a directory, not a file",
        )
    }
}

fn default_state_dir() -> Result<PathBuf> {
    let home = home_dir()?;
    #[cfg(target_os = "macos")]
    {
        Ok(home
            .join("Library")
            .join("Application Support")
            .join("SnagTorrent"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(match std::env::var_os("XDG_DATA_HOME") {
            Some(path) => PathBuf::from(path).join("snagtorrent"),
            None => home.join(".local").join("share").join("snagtorrent"),
        })
    }
}

fn home_dir() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .context("HOME is not set to an absolute path")
}

pub fn create_private_dir(path: &Path) -> Result<()> {
    if path.symlink_metadata().is_ok_and(|meta| meta.is_symlink()) {
        bail!(
            "refusing to use a symlink as the state directory: {}",
            path.display()
        );
    }
    fs::create_dir_all(path)
        .with_context(|| format!("could not create state directory {}", path.display()))?;
    let metadata = path.metadata()?;
    if !metadata.is_dir() {
        bail!("state path is not a directory: {}", path.display());
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_from_before_pause_when_done_defaults_to_on() {
        let config: Config = serde_json::from_str(r#"{"download_dir":"/tmp/dl"}"#).unwrap();
        assert!(config.pause_when_done);
    }

    #[test]
    fn relative_download_dir_is_rejected() {
        let config = Config {
            download_dir: PathBuf::from("relative/dir"),
            pause_when_done: true,
        };
        assert!(config.ensure_download_dir().is_err());
    }
}
