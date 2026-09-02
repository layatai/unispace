use crate::model::{DeviceDescriptor, DisplayDescriptor, DisplayRect, Identifier};
use std::{net::UdpSocket, process::Command};
use uuid::Uuid;

/// Descriptor advertised during pairing: device id (persisted once paired),
/// hostname, local addresses, and the primary display geometry.
pub fn local_descriptor() -> DeviceDescriptor {
    let device_id = crate::config::Configuration::load()
        .map(|configuration| configuration.device_id)
        .unwrap_or_else(|_| Uuid::new_v4());
    DeviceDescriptor::linux(
        device_id,
        hostname(),
        local_addresses(),
        vec![display(device_id)],
    )
}

pub fn hostname() -> String {
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

/// The compositor's real cursor position (Hyprland first). Pointer
/// acceleration makes injected relative motion diverge from the raw delta
/// sum, so boundary detection must trust this, not the accumulated value.
pub fn cursor_position() -> Option<(f64, f64)> {
    let runtime = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
    let signature = std::fs::read_dir(format!("{runtime}/hypr"))
        .ok()?
        .flatten()
        .find(|entry| entry.file_type().map(|t| t.is_dir()).unwrap_or(false))?
        .file_name()
        .into_string()
        .ok()?;
    let output = Command::new("hyprctl")
        .arg("cursorpos")
        .env("XDG_RUNTIME_DIR", &runtime)
        .env("HYPRLAND_INSTANCE_SIGNATURE", signature)
        .output()
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    let (x, y) = text.trim().split_once(", ")?;
    Some((x.trim().parse().ok()?, y.trim().parse().ok()?))
}

fn screen_size() -> (u32, u32) {
    // Hyprland (Wayland): `hyprctl monitors` reports `WxH@refresh at XxY`.
    if let Some((w, h)) = hypr_monitor_size() {
        return (w, h);
    }
    // X11: parse the first connected output mode from xrandr.
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

fn hypr_monitor_size() -> Option<(u32, u32)> {
    // The session env is absent over SSH; derive it from the runtime dir.
    let uid = unsafe { libc::getuid() };
    let runtime = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{uid}"));
    let instance = std::fs::read_dir(format!("{runtime}/hypr"))
        .ok()?
        .flatten()
        .find(|entry| entry.file_type().map(|t| t.is_dir()).unwrap_or(false))?
        .file_name()
        .into_string()
        .ok();
    let output = Command::new("hyprctl")
        .arg("monitors")
        .env("XDG_RUNTIME_DIR", &runtime)
        .env("HYPRLAND_INSTANCE_ID", instance?)
        .output()
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    // First monitor line looks like: `Monitor eDP-1 (ID 0):`
    // followed by `	1366x768@60.01600 at 0x0`.
    for line in text.lines() {
        let line = line.trim_start();
        if !line.contains("@") || !line.contains(" at ") || !line.contains('x') {
            continue;
        }
        let mode = line.split('@').next()?;
        let (w, h) = mode.split_once('x')?;
        if let (Ok(w), Ok(h)) = (w.trim().parse(), h.trim().parse()) {
            return Some((w, h));
        }
    }
    None
}
