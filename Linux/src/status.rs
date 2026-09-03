use crate::observe::{StatusHub, transfers_root};
use ksni::{MenuItem, ToolTip, Tray, TrayMethods, menu::StandardItem};
use std::process::Command;

pub struct StatusTray {
    title: String,
}

impl StatusTray {
    fn open() {
        if let Ok(exe) = std::env::current_exe()
            && let Some(dir) = exe.parent()
        {
            let ui = dir.join("unispace-linux-ui");
            // Preferred: launch inside the user session; the systemd user
            // manager carries the desktop environment the webview needs.
            if Command::new("systemd-run")
                .args([
                    "--user",
                    "--collect",
                    "--unit=unispace-ui",
                    &ui.to_string_lossy(),
                ])
                .status()
                .map(|status| status.success())
                .unwrap_or(false)
            {
                return;
            }
            // Fallback: derive the session environment ourselves — a daemon
            // launched over SSH has no WAYLAND_DISPLAY/DBUS and the window
            // would silently never appear.
            let mut command = Command::new(&ui);
            let uid = unsafe { libc::getuid() };
            let runtime =
                std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{uid}"));
            command.env("XDG_RUNTIME_DIR", &runtime);
            if std::env::var_os("WAYLAND_DISPLAY").is_none()
                && std::env::var_os("DISPLAY").is_none()
                && let Some(wayland) = std::fs::read_dir(&runtime).ok().and_then(|entries| {
                    entries
                        .flatten()
                        .map(|entry| entry.file_name())
                        .find(|name| name.to_string_lossy().starts_with("wayland-"))
                })
            {
                command.env("WAYLAND_DISPLAY", wayland);
                command.env("DISPLAY", ":0");
            }
            if std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_none() {
                command.env(
                    "DBUS_SESSION_BUS_ADDRESS",
                    format!("unix:path={runtime}/bus"),
                );
            }
            let _ = command.spawn();
        }
    }

    fn open_received_files() {
        if let Ok(root) = transfers_root() {
            let _ = std::fs::create_dir_all(&root);
            let _ = Command::new("xdg-open").arg(root).spawn();
        }
    }
}

impl Tray for StatusTray {
    fn id(&self) -> String {
        "com.layatai.unispace".into()
    }
    fn title(&self) -> String {
        self.title.clone()
    }
    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            title: self.title.clone(),
            ..Default::default()
        }
    }
    fn icon_name(&self) -> String {
        "input-mouse".into()
    }
    fn activate(&mut self, _x: i32, _y: i32) {
        Self::open()
    }
    fn menu(&self) -> Vec<MenuItem<Self>> {
        vec![
            StandardItem {
                label: "Open UniSpace".into(),
                activate: Box::new(|_| Self::open()),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Open Received Files".into(),
                activate: Box::new(|_| Self::open_received_files()),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Quit Receiver".into(),
                activate: Box::new(|_| std::process::exit(0)),
                ..Default::default()
            }
            .into(),
        ]
    }
}

pub async fn start(hub: StatusHub) {
    // ksni's tray loop drives a blocking D-Bus connection; run it on a
    // dedicated thread so it never block_on's the async runtime.
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tray runtime");
        runtime.block_on(async move {
            let tray = StatusTray {
                title: hub.snapshot().tray_title(),
            };
            match tray.assume_sni_available(true).spawn().await {
                Ok(handle) => {
                    let mut rx = hub.subscribe();
                    loop {
                        if rx.changed().await.is_err() {
                            break;
                        }
                        let title = rx.borrow().tray_title();
                        handle
                            .update(|tray| {
                                tray.title = title.clone();
                            })
                            .await;
                    }
                    std::future::pending::<()>().await
                }
                Err(error) => tracing::warn!(%error, "status tray unavailable"),
            }
        });
    });
}

pub fn notify(summary: &str, body: &str) {
    // notify-rust's sync API block_on's its own D-Bus connection, which panics
    // inside the tokio runtime; run it on a plain thread instead.
    let summary = summary.to_owned();
    let body = body.to_owned();
    std::thread::spawn(move || {
        let _ = notify_rust::Notification::new()
            .appname("UniSpace Receiver")
            .summary(&summary)
            .body(&body)
            .icon("input-mouse")
            .show();
    });
}
