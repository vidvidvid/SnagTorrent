mod client;
mod daemon;
mod paths;
mod protocol;
mod stream;

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
        #[arg(
            long,
            value_delimiter = ',',
            help = "Download only these file indices (comma-separated; see `snag files`)"
        )]
        only: Option<Vec<usize>>,
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
    #[command(about = "Choose which files of a torrent to download (indices from `snag files`)")]
    Select {
        id: usize,
        #[arg(
            required = true,
            help = "File indices to download; all other files are skipped"
        )]
        files: Vec<usize>,
    },
    #[command(about = "List a torrent's files with their indices")]
    Files { id: usize },
    #[command(about = "Show or change settings")]
    Config {
        #[arg(
            long,
            help = "Pause torrents when they finish instead of seeding (true/false)"
        )]
        pause_when_done: Option<bool>,
    },
    #[command(about = "Print a local URL that streams a file while it downloads")]
    Stream { id: usize, file: usize },
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
                let mut config = paths.load_config()?;
                config.download_dir = download_dir;
                config.download_dir = config.ensure_download_dir()?;
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
            only,
        } => {
            let source = client::normalize_source(&source)?;
            let response = client::call(
                &paths,
                Request::Add {
                    source,
                    paused,
                    initial_peers,
                    only_files: only,
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
        Command::Select { id, files } => {
            let response = client::call(&paths, Request::SetFiles { id, files }).await?;
            print_message(&response.message);
            Ok(())
        }
        Command::Files { id } => {
            let response = client::call(&paths, Request::List).await?;
            let torrent = response
                .torrents
                .iter()
                .find(|torrent| torrent.id == id)
                .ok_or_else(|| anyhow::anyhow!("no torrent with ID {id}"))?;
            if torrent.files.is_empty() {
                println!("No file list yet; metadata is still being fetched");
                return Ok(());
            }
            println!("{:<5} {:<4} {:>10}  PATH", "INDEX", "GET", "SIZE");
            for (index, file) in torrent.files.iter().enumerate() {
                println!(
                    "{:<5} {:<4} {:>10}  {}",
                    index,
                    if file.selected { "yes" } else { "no" },
                    human_bytes(file.length),
                    display_name(&file.path)
                );
            }
            Ok(())
        }
        Command::Config { pause_when_done } => {
            let request = match pause_when_done {
                Some(_) => Request::Configure { pause_when_done },
                None => Request::Status,
            };
            let response = client::call(&paths, request).await?;
            if let Some(status) = response.status {
                println!("Version:          {}", status.version);
                println!("Downloads:        {}", status.download_dir);
                println!("Pause when done:  {}", status.pause_when_done);
                println!("Stream port:      {}", status.stream_port);
            }
            Ok(())
        }
        Command::Stream { id, file } => {
            let response = client::call(&paths, Request::StreamUrl { id, file }).await?;
            print_message(&response.stream_url);
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
