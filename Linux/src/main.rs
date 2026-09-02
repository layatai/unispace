use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::{
    io::{self, Write},
    process::Command,
};
use unispace_linux::{
    clipboard, config::Configuration, files, host, input::UinputSink, pairing::PendingPairing,
    receiver, service, status,
};

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
            let gesture_bindings = configuration.resolved_gesture_bindings();
            receiver::run(configuration, UinputSink::open(gesture_bindings)?).await
        }
        CommandKind::Status => {
            match Configuration::load() {
                Ok(c) => println!("Paired with {} at {}", c.workspace.name, c.host_address),
                Err(_) => println!("Not paired"),
            };
            Ok(())
        }
        CommandKind::Open => open_ui().await,
        CommandKind::Unpair => {
            service::stop()?;
            if let Ok(configuration) = Configuration::load() {
                configuration.remove()?;
            }
            println!("Local workspace membership removed.");
            Ok(())
        }
    }
}

async fn pair(address: String) -> Result<()> {
    let descriptor = host::local_descriptor();
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
    if let Err(error) = service::start() {
        eprintln!(
            "Joined {}, but the receiver service did not start: {error}",
            configuration.workspace.name
        );
        eprintln!(
            "Run `systemctl --user enable --now unispace.service` after installing the unit."
        );
    } else {
        println!("Joined {}. Receiver started.", configuration.workspace.name);
    }
    Ok(())
}

async fn open_ui() -> Result<()> {
    let exe = std::env::current_exe()
        .context("resolve executable")?
        .parent()
        .expect("executable parent")
        .join("unispace-linux-ui");
    Command::new(&exe).spawn().with_context(|| {
        format!(
            "launch {} (is it installed alongside unispace-linux?)",
            exe.display()
        )
    })?;
    Ok(())
}
