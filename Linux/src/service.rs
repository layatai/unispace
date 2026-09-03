use anyhow::{Context, Result, ensure};
use std::process::{Command, Output};

const UNIT: &str = "unispace.service";

pub fn start() -> Result<()> {
    let output = systemctl(&["enable", "--now", UNIT])?;
    ensure!(
        output.status.success(),
        "systemctl --user enable --now {UNIT}: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(())
}

pub fn stop() -> Result<()> {
    let output = systemctl(&["stop", UNIT])?;
    let error = String::from_utf8_lossy(&output.stderr);
    ensure!(
        output.status.success() || missing_unit(&error),
        "systemctl --user stop {UNIT}: {}",
        error.trim()
    );
    Ok(())
}

pub fn is_active() -> bool {
    systemctl(&["is-active", "--quiet", UNIT])
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn systemctl(arguments: &[&str]) -> Result<Output> {
    Command::new("systemctl")
        .arg("--user")
        .args(arguments)
        .output()
        .context("run systemctl --user")
}

fn missing_unit(error: &str) -> bool {
    ["not loaded", "not found", "does not exist"]
        .iter()
        .any(|message| error.contains(message))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_user_unit_is_safe_to_stop() {
        assert!(missing_unit("Unit unispace.service not loaded."));
        assert!(!missing_unit("Failed to connect to bus: Permission denied"));
    }
}
