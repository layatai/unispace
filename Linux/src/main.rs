use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::{
    io::{self, Write},
    net::UdpSocket,
    process::Command,
};
use unispace_linux::{
    clipboard,
    config::Configuration,
    files,
    input::UinputSink,
    model::{DeviceDescriptor, DisplayDescriptor, DisplayRect, Identifier},
    pairing::PendingPairing,
    receiver, status,
};
use uuid::Uuid;

#[derive(Parser)]
#[command(
    name = "unispace-linux",
    version,
    about = "UniSpace receiver for Linux"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<CommandKind>,
}
#[derive(Subcommand)]
enum CommandKind {
    Pair { address: String },
    Run,
    Status,
    Open,
    Unpair,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("unispace_linux=info".parse()?),
        )
        .init();
    match Cli::parse().command.unwrap_or(CommandKind::Open) {
        CommandKind::Pair { address } => pair(address).await,
        CommandKind::Run => {
            let configuration = Configuration::load()
                .context("UniSpace is not paired; run `unispace-linux pair HOST`")?;
            tokio::spawn(status::start());
            tokio::spawn(clipboard::supervise(configuration.clone()));
            tokio::spawn(files::supervise(configuration.clone()));
            receiver::run(configuration, UinputSink::open()?).await
        }
        CommandKind::Status => {
            match Configuration::load() {
                Ok(c) => println!("Paired with {} at {}", c.workspace.name, c.host_address),
                Err(_) => println!("Not paired"),
            };
            Ok(())
        }
        CommandKind::Open => open_configuration().await,
        CommandKind::Unpair => {
            if let Ok(configuration) = Configuration::load() {
                configuration.remove()?;
            }
            println!("Local workspace membership removed.");
            Ok(())
        }
    }
}

async fn pair(address: String) -> Result<()> {
    let descriptor = local_descriptor();
    let pending = PendingPairing::begin(&address, &descriptor).await?;
    println!(
        "Confirm that {} shows this code: {}",
        pending.peer_name, pending.code
    );
    print!("Codes match? [y/N] ");
    io::stdout().flush()?;
    let mut answer = String::new();
    io::stdin().read_line(&mut answer)?;
    if !matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes") {
        anyhow::bail!("pairing cancelled")
    }
    let configuration = pending.confirm(address).await?;
    println!(
        "Joined {}. Start the receiver with `systemctl --user enable --now unispace.service`.",
        configuration.workspace.name
    );
    Ok(())
}

async fn open_configuration() -> Result<()> {
    if let Ok(configuration) = Configuration::load() {
        let message = format!(
            "Paired with {} at {}",
            configuration.workspace.name, configuration.host_address
        );
        if Command::new("zenity")
            .args(["--info", "--title=UniSpace Receiver", "--text", &message])
            .status()
            .is_err()
        {
            println!("{message}");
        }
        return Ok(());
    }

    let output = Command::new("zenity")
        .args([
            "--entry",
            "--title=Pair UniSpace",
            "--text=Enter the controller Mac's hostname or IP address:",
            "--entry-text=macbook.local",
        ])
        .output()
        .context(
            "Zenity is required for graphical pairing; use `unispace-linux pair HOST` instead",
        )?;
    if !output.status.success() {
        return Ok(());
    }
    let address = String::from_utf8(output.stdout)?.trim().to_owned();
    let pending = PendingPairing::begin(&address, &local_descriptor()).await?;
    let prompt = format!(
        "Confirm that {} shows the same code:\n\n{}",
        pending.peer_name, pending.code
    );
    let accepted = Command::new("zenity")
        .args([
            "--question",
            "--title=Confirm UniSpace Pairing",
            "--ok-label=Codes Match",
            "--cancel-label=Cancel",
            "--text",
            &prompt,
        ])
        .status()?
        .success();
    if accepted {
        let configuration = pending.confirm(address).await?;
        status::notify(
            "UniSpace paired",
            &format!("Joined {}", configuration.workspace.name),
        );
    }
    Ok(())
}

fn local_descriptor() -> DeviceDescriptor {
    let device_id = Configuration::load()
        .map(|configuration| configuration.device_id)
        .unwrap_or_else(|_| Uuid::new_v4());
    DeviceDescriptor::linux(
        device_id,
        hostname(),
        local_addresses(),
        vec![display(device_id)],
    )
}

fn hostname() -> String {
    std::fs::read_to_string("/etc/hostname")
        .map(|s| s.trim().to_owned())
        .unwrap_or_else(|_| "Linux PC".into())
}
fn local_addresses() -> Vec<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok();
    socket
        .and_then(|s| {
            s.connect("1.1.1.1:80").ok()?;
            Some(s.local_addr().ok()?.ip().to_string())
        })
        .into_iter()
        .collect()
}
fn display(device_id: Uuid) -> DisplayDescriptor {
    let (width, height) = screen_size();
    let mut bytes = *device_id.as_bytes();
    bytes[0] ^= 0x4c;
    bytes[6] = (bytes[6] & 0x0f) | 0x80;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    DisplayDescriptor {
        id: Identifier {
            raw_value: Uuid::from_bytes(bytes),
        },
        device_id: Identifier {
            raw_value: device_id,
        },
        name: "Linux Desktop".into(),
        frame: DisplayRect {
            x: 0.0,
            y: 0.0,
            width: width as f64,
            height: height as f64,
        },
        scale_factor: 1.0,
        is_main: true,
    }
}
fn screen_size() -> (u32, u32) {
    let output = Command::new("xrandr").arg("--current").output().ok();
    let text = output
        .as_ref()
        .and_then(|o| std::str::from_utf8(&o.stdout).ok())
        .unwrap_or("");
    for line in text.lines().filter(|line| line.contains(" connected")) {
        for token in line.split_whitespace() {
            if let Some((w, h)) = token.split_once('x') {
                let h = h.split('+').next().unwrap_or(h);
                if let (Ok(w), Ok(h)) = (w.parse(), h.parse()) {
                    return (w, h);
                }
            }
        }
    }
    (1920, 1080)
}
