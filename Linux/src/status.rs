use ksni::{MenuItem, Tray, TrayMethods, menu::StandardItem};
use std::process::Command;

pub struct StatusTray;
impl StatusTray {
    fn open() {
        if let Ok(exe) = std::env::current_exe()
            && let Some(dir) = exe.parent()
        {
            let _ = Command::new(dir.join("unispace-linux-ui")).spawn();
        }
    }
}
impl Tray for StatusTray {
    fn id(&self) -> String {
        "com.layatai.unispace".into()
    }
    fn title(&self) -> String {
        "UniSpace Receiver".into()
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
                label: "Quit Receiver".into(),
                activate: Box::new(|_| std::process::exit(0)),
                ..Default::default()
            }
            .into(),
        ]
    }
}
pub async fn start() {
    // ksni's tray loop drives a blocking D-Bus connection; run it on a
    // dedicated thread so it never block_on's the async runtime.
    std::thread::spawn(|| {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tray runtime");
        runtime.block_on(async {
            match StatusTray.assume_sni_available(true).spawn().await {
                Ok(_handle) => std::future::pending::<()>().await,
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
