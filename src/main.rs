mod client;
mod daemon;
mod paths;
mod protocol;

use std::{net::SocketAddr, path::PathBuf};

use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use protocol::{Request, TorrentSummary};

#[derive(Parser)]
#[command(
    name = "snag",
    version,
    about = "SnagTorrent — a tiny, private BitTorrent client",
    long_about = "A lightweight BitTorrent client with no web UI or remote control port. Downloads run in a user-only background daemon."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    #[command(about = "Start the background daemon")]
    Start {
        #[arg(long, help = "Set the download directory before starting")]
        download_dir: Option<PathBuf>,
    },
    #[command(about = "Add a magnet link, info hash, torrent URL, or .torrent file")]
    Add {
        source: String,
        #[arg(long, help = "Add without downloading yet")]
        paused: bool,
        #[arg(long = "peer", help = "Connect to an initial peer (IP:PORT)")]
        initial_peers: Vec<SocketAddr>,
    },
    #[command(about = "List torrents, progress, and current speeds")]
    List,
    #[command(about = "Pause a torrent")]
    Pause { id: usize },
    #[command(about = "Resume a torrent")]
    Resume { id: usize },
    #[command(about = "Remove a torrent; keep downloaded files by default")]
    Remove {
        id: usize,
        #[arg(long, help = "Also delete this torrent's files from disk")]
        delete_files: bool,
    },
    #[command(about = "Stop the background daemon")]
    Stop,
    #[command(hide = true)]
    Serve,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    if let Err(error) = dispatch(cli).await {
        eprintln!("snag: {error:#}");
        std::process::exit(1);
    }
}

async fn dispatch(cli: Cli) -> Result<()> {
    let paths = paths::AppPaths::discover()?;
    match cli.command {
        Command::Serve => {
            init_logging();
            daemon::run(paths).await
        }
        Command::Start { download_dir } => {
            paths.prepare()?;
            if client::call_without_start(&paths, Request::Ping)
                .await
                .is_ok()
            {
                if download_dir.is_some() {
                    bail!("stop SnagTorrent before changing the download directory");
                }
                println!("SnagTorrent is already running");
                return Ok(());
            }
            if let Some(download_dir) = download_dir {
                let download_dir = absolute_path(download_dir)?;
                let config = paths::Config { download_dir };
                let config = paths::Config {
                    download_dir: config.ensure_download_dir()?,
                };
                paths.save_config(&config)?;
            }
            client::ensure_running(&paths).await?;
            let config = paths.load_config()?;
            println!("SnagTorrent is running");
            println!("Downloads: {}", config.download_dir.display());
            Ok(())
        }
        Command::Add {
            source,
            paused,
            initial_peers,
        } => {
            let source = client::normalize_source(&source)?;
            let response = client::call(
                &paths,
                Request::Add {
                    source,
                    paused,
                    initial_peers,
                },
            )
            .await?;
            print_message(&response.message);
            if let Some(torrent) = response.torrents.first() {
                println!("{}", display_name(&torrent.name));
            }
            Ok(())
        }
        Command::List => {
            let response = client::call(&paths, Request::List).await?;
            print_list(&response.torrents);
            Ok(())
        }
        Command::Pause { id } => {
            let response = client::call(&paths, Request::Pause { id }).await?;
            print_message(&response.message);
            Ok(())
        }
        Command::Resume { id } => {
            let response = client::call(&paths, Request::Resume { id }).await?;
            print_message(&response.message);
            Ok(())
        }
        Command::Remove { id, delete_files } => {
            let response = client::call(&paths, Request::Remove { id, delete_files }).await?;
            print_message(&response.message);
            Ok(())
        }
        Command::Stop => {
            match client::call_without_start(&paths, Request::Shutdown).await {
                Ok(response) => print_message(&response.message),
                Err(_) => println!("SnagTorrent is not running"),
            }
            Ok(())
        }
    }
}

fn absolute_path(path: PathBuf) -> Result<PathBuf> {
    if path.is_absolute() {
        Ok(path)
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn print_message(message: &Option<String>) {
    if let Some(message) = message {
        println!("{message}");
    }
}

fn print_list(torrents: &[TorrentSummary]) {
    if torrents.is_empty() {
        println!("No torrents. Add one with: snag add <magnet-or-file>");
        return;
    }
    println!(
        "{:<4} {:<13} {:>7} {:>12} {:>12}  NAME",
        "ID", "STATE", "PROGRESS", "DOWN", "UP"
    );
    for torrent in torrents {
        let progress = if torrent.total_bytes == 0 {
            0.0
        } else {
            torrent.progress_bytes as f64 * 100.0 / torrent.total_bytes as f64
        };
        println!(
            "{:<4} {:<13} {:>6.1}% {:>12} {:>12}  {}",
            torrent.id,
            torrent.state,
            progress,
            format_rate(torrent.download_speed),
            format_rate(torrent.upload_speed),
            display_name(&torrent.name)
        );
        if let Some(error) = &torrent.error {
            println!("     {}", sanitize(error));
        }
    }
}

fn display_name(name: &str) -> String {
    const MAX_CHARS: usize = 100;
    let sanitized = sanitize(name);
    if sanitized.chars().count() <= MAX_CHARS {
        sanitized
    } else {
        let truncated = sanitized.chars().take(MAX_CHARS).collect::<String>();
        format!("{truncated}…")
    }
}

fn sanitize(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_control() || character == '\u{7f}' {
                '�'
            } else {
                character
            }
        })
        .collect()
}

fn format_rate(bytes_per_second: u64) -> String {
    if bytes_per_second == 0 {
        return "—".to_owned();
    }
    format!("{}/s", human_bytes(bytes_per_second))
}

fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} {}", UNITS[unit])
    } else if value >= 10.0 {
        format!("{value:.0} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn init_logging() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .init();
}
