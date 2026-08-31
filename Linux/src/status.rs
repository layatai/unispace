use ksni::{MenuItem, Tray, TrayMethods, menu::StandardItem};
use std::process::Command;

pub struct StatusTray;
impl StatusTray {
    fn open() {
        if let Ok(exe) = std::env::current_exe() {
            let _ = Command::new(exe).arg("open").spawn();
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
    let _ = StatusTray.assume_sni_available(true).spawn().await;
}
pub fn notify(summary: &str, body: &str) {
    let _ = notify_rust::Notification::new()
        .appname("UniSpace Receiver")
        .summary(summary)
        .body(body)
        .icon("input-mouse")
        .show();
}
