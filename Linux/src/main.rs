use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::{
    io::{self, Write},
    process::Command,
};
use unispace_linux::{
    clipboard,
    config::Configuration,
    files, host,
    input::{InputSink, NullInputSink, UinputSink},
    observe,
    pairing::PendingPairing,
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
    let filter = match std::env::var_os("RUST_LOG") {
        Some(_) => tracing_subscriber::EnvFilter::from_default_env(),
        None => tracing_subscriber::EnvFilter::new("unispace_linux=info"),
    };
    tracing_subscriber::fmt().with_env_filter(filter).init();
    match Cli::parse().command.unwrap_or(CommandKind::Open) {
        CommandKind::Pair { address } => pair(address).await,
        CommandKind::Run => {
            let configuration = Configuration::load()
                .context("UniSpace is not paired; run `unispace-linux pair HOST`")?;
            let (hub, send_files) = observe::StatusHub::new(
                observe::ReceiverSnapshot::from_configuration(&configuration),
            );
            tokio::spawn(observe::serve(hub.clone()));
            tokio::spawn(status::start(hub.clone()));
            tokio::spawn(clipboard::supervise(configuration.clone(), hub.clone()));
            tokio::spawn(files::supervise(
                configuration.clone(),
                hub.clone(),
                send_files,
            ));
            let gesture_bindings = configuration.resolved_gesture_bindings();
            let display = configuration
                .workspace
                .devices
                .iter()
                .find(|device| device.id.raw_value == configuration.device_id)
                .and_then(|device| device.displays.first())
                .cloned()
                .context("local display missing from the paired workspace")?;
            let width = display.frame.width as i32;
            let height = display.frame.height as i32;
            match UinputSink::open(gesture_bindings, width, height) {
                Ok(input) => {
                    hub.set_uinput_ready(true);
                    run_receiver(configuration, input, hub).await
                }
                Err(error) => {
                    tracing::warn!(
                        %error,
                        "uinput unavailable; control input disabled until this session has the unispace group (sign out and back in)"
                    );
                    hub.set_uinput_ready(false);
                    run_receiver(configuration, NullInputSink, hub).await
                }
            }
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

async fn run_receiver(
    configuration: Configuration,
    input: impl InputSink + 'static,
    hub: observe::StatusHub,
) -> Result<()> {
    receiver::run(configuration, input, hub).await
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
