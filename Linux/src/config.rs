use crate::model::WorkspaceSnapshot;
use anyhow::{Context, Result};
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::{fs, io::Write, path::PathBuf};
use uuid::Uuid;

const KEYRING_SERVICE: &str = "com.layatai.unispace.linux";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Configuration {
    pub device_id: Uuid,
    pub host_address: String,
    pub workspace: WorkspaceSnapshot,
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
