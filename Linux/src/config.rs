use crate::model::WorkspaceSnapshot;
use anyhow::{Context, Result};
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::{fs, io::Write, path::PathBuf};
use uuid::Uuid;

const KEYRING_SERVICE: &str = "com.layatai.unispace.linux";

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GestureProfile {
    #[default]
    Auto,
    Hyprland,
    Gnome,
    Kde,
    Disabled,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GestureKey {
    LeftCtrl,
    LeftShift,
    LeftAlt,
    LeftMeta,
    Left,
    Right,
    Tab,
    Space,
    A,
    D,
    S,
    Equal,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct GestureBindings {
    pub profile: GestureProfile,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub navigation_back: Option<Vec<GestureKey>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub navigation_forward: Option<Vec<GestureKey>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_previous: Option<Vec<GestureKey>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_next: Option<Vec<GestureKey>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_up: Option<Vec<GestureKey>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_down: Option<Vec<GestureKey>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub smart_magnify: Option<Vec<GestureKey>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pinch_in: Option<Vec<GestureKey>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spread: Option<Vec<GestureKey>>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ResolvedGestureBindings {
    pub navigation_back: Option<Vec<GestureKey>>,
    pub navigation_forward: Option<Vec<GestureKey>>,
    pub workspace_previous: Option<Vec<GestureKey>>,
    pub workspace_next: Option<Vec<GestureKey>>,
    pub workspace_up: Option<Vec<GestureKey>>,
    pub workspace_down: Option<Vec<GestureKey>>,
    pub smart_magnify: Option<Vec<GestureKey>>,
    pub pinch_in: Option<Vec<GestureKey>>,
    pub spread: Option<Vec<GestureKey>>,
}

impl GestureBindings {
    pub fn resolve(&self, desktop: Option<&str>) -> ResolvedGestureBindings {
        let profile = match self.profile {
            GestureProfile::Auto => detect_desktop(desktop),
            profile => profile,
        };
        let defaults = profile_defaults(profile);
        ResolvedGestureBindings {
            navigation_back: self.navigation_back.clone().or(defaults.navigation_back),
            navigation_forward: self
                .navigation_forward
                .clone()
                .or(defaults.navigation_forward),
            workspace_previous: self
                .workspace_previous
                .clone()
                .or(defaults.workspace_previous),
            workspace_next: self.workspace_next.clone().or(defaults.workspace_next),
            workspace_up: self.workspace_up.clone().or(defaults.workspace_up),
            workspace_down: self.workspace_down.clone().or(defaults.workspace_down),
            smart_magnify: self.smart_magnify.clone().or(defaults.smart_magnify),
            pinch_in: self.pinch_in.clone().or(defaults.pinch_in),
            spread: self.spread.clone().or(defaults.spread),
        }
    }
}

fn detect_desktop(desktop: Option<&str>) -> GestureProfile {
    let desktop = desktop.unwrap_or_default().to_ascii_lowercase();
    if desktop.contains("hyprland") || desktop.contains("omarchy") {
        GestureProfile::Hyprland
    } else if desktop.contains("kde") || desktop.contains("plasma") {
        GestureProfile::Kde
    } else {
        GestureProfile::Gnome
    }
}

fn profile_defaults(profile: GestureProfile) -> ResolvedGestureBindings {
    use GestureKey::*;
    let chord = |keys: &[GestureKey]| Some(keys.to_vec());
    match profile {
        GestureProfile::Hyprland => ResolvedGestureBindings {
            navigation_back: chord(&[LeftAlt, Left]),
            navigation_forward: chord(&[LeftAlt, Right]),
            workspace_previous: chord(&[LeftMeta, LeftShift, Tab]),
            workspace_next: chord(&[LeftMeta, Tab]),
            workspace_up: chord(&[LeftMeta, Space]),
            workspace_down: chord(&[LeftMeta, S]),
            smart_magnify: chord(&[LeftCtrl, LeftShift, Equal]),
            pinch_in: chord(&[LeftMeta, LeftAlt, Space]),
            spread: chord(&[LeftMeta, S]),
        },
        GestureProfile::Disabled => ResolvedGestureBindings::default(),
        GestureProfile::Auto | GestureProfile::Gnome | GestureProfile::Kde => {
            ResolvedGestureBindings {
                navigation_back: chord(&[LeftAlt, Left]),
                navigation_forward: chord(&[LeftAlt, Right]),
                workspace_previous: chord(&[LeftCtrl, LeftMeta, Left]),
                workspace_next: chord(&[LeftCtrl, LeftMeta, Right]),
                workspace_up: chord(&[LeftMeta, Tab]),
                workspace_down: chord(&[LeftMeta, D]),
                smart_magnify: chord(&[LeftCtrl, LeftShift, Equal]),
                pinch_in: chord(&[LeftMeta, A]),
                spread: chord(&[LeftMeta, D]),
            }
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Configuration {
    pub device_id: Uuid,
    pub host_address: String,
    pub workspace: WorkspaceSnapshot,
    #[serde(default)]
    pub gesture_bindings: GestureBindings,
}

impl Configuration {
    pub fn path() -> Result<PathBuf> {
        Ok(ProjectDirs::from("com", "layatai", "UniSpace")
            .context("home directory unavailable")?
            .config_dir()
            .join("receiver.json"))
    }
    pub fn load() -> Result<Self> {
        Ok(serde_json::from_slice(&fs::read(Self::path()?)?)?)
    }
    pub fn save(&self, workspace_key: &[u8]) -> Result<()> {
        let path = Self::path()?;
        fs::create_dir_all(path.parent().unwrap())?;
        let entry = keyring::Entry::new(KEYRING_SERVICE, &self.workspace.id.raw_value.to_string())?;
        entry
            .set_password(&BASE64.encode(workspace_key))
            .context("store workspace key in Secret Service")?;
        let temp = path.with_extension("tmp");
        let mut options = fs::OpenOptions::new();
        options.create(true).truncate(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temp)?;
        file.write_all(&serde_json::to_vec_pretty(self)?)?;
        file.sync_all()?;
        fs::rename(temp, path)?;
        Ok(())
    }
    pub fn workspace_key(&self) -> Result<Vec<u8>> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, &self.workspace.id.raw_value.to_string())?;
        BASE64
            .decode(entry.get_password()?)
            .context("decode workspace key")
    }

    pub fn resolved_gesture_bindings(&self) -> ResolvedGestureBindings {
        self.gesture_bindings
            .resolve(std::env::var("XDG_CURRENT_DESKTOP").ok().as_deref())
    }

    pub fn replace_workspace_key(&self, workspace_key: &[u8]) -> Result<()> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, &self.workspace.id.raw_value.to_string())?;
        entry
            .set_password(&BASE64.encode(workspace_key))
            .context("replace workspace key in Secret Service")
    }

    pub fn remove(&self) -> Result<()> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, &self.workspace.id.raw_value.to_string())?;
        let _ = entry.delete_credential();
        let path = Self::path()?;
        if path.exists() {
            fs::remove_file(path)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_profile_uses_hyprland_defaults_and_honors_disabling_override() {
        let bindings = GestureBindings {
            workspace_down: Some(Vec::new()),
            ..Default::default()
        }
        .resolve(Some("Hyprland"));

        assert_eq!(
            bindings.workspace_previous,
            Some(vec![
                GestureKey::LeftMeta,
                GestureKey::LeftShift,
                GestureKey::Tab
            ])
        );
        assert_eq!(bindings.workspace_down, Some(Vec::new()));
        assert_eq!(
            bindings.pinch_in,
            Some(vec![
                GestureKey::LeftMeta,
                GestureKey::LeftAlt,
                GestureKey::Space
            ])
        );
    }

    #[test]
    fn symbolic_gesture_bindings_round_trip() {
        let value = serde_json::json!({
            "profile": "kde",
            "navigationBack": ["leftAlt", "left"]
        });
        let decoded: GestureBindings = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(decoded).unwrap(), value);
    }
}
