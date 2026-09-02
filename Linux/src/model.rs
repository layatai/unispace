use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct BareUuid(pub Uuid);

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Identifier {
    pub raw_value: Uuid,
}

impl Identifier {
    pub fn new() -> Self {
        Self {
            raw_value: Uuid::new_v4(),
        }
    }
}

impl Default for Identifier {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayDescriptor {
    pub id: Identifier,
    #[serde(rename = "deviceID")]
    pub device_id: Identifier,
    pub name: String,
    pub frame: DisplayRect,
    pub scale_factor: f64,
    pub is_main: bool,
}

/// A peer address encodes as a plain string on the wire (matching the Swift
/// single-value-container Codable impl).
#[derive(Clone, Debug, PartialEq)]
pub struct PeerAddress {
    pub host: String,
}

impl serde::Serialize for PeerAddress {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.host)
    }
}

impl<'de> serde::Deserialize<'de> for PeerAddress {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Self {
            host: String::deserialize(deserializer)?,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RawValue {
    pub raw_value: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceDescriptor {
    pub id: Identifier,
    pub name: String,
    #[serde(default)]
    pub displays: Vec<DisplayDescriptor>,
    #[serde(default)]
    pub peer_addresses: Vec<PeerAddress>,
    #[serde(default)]
    pub capabilities: BTreeSet<String>,
    pub platform: RawValue,
}

impl DeviceDescriptor {
    pub fn linux(
        id: Uuid,
        name: String,
        addresses: Vec<String>,
        displays: Vec<DisplayDescriptor>,
    ) -> Self {
        Self {
            id: Identifier { raw_value: id },
            name,
            displays,
            peer_addresses: addresses
                .into_iter()
                .map(|host| PeerAddress { host })
                .collect(),
            capabilities: [
                "portable-trackpad-gestures-v1",
                "cross-platform-input-v2",
                "udp-pointer-v2",
                "realtime-pointer-progress-v1",
                "activation-ack-v1",
                "file-transfer-v1",
                "clipboard-text-v1",
                "clipboard-url-v1",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            platform: RawValue {
                raw_value: "linux".into(),
            },
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSnapshot {
    pub id: Identifier,
    pub name: String,
    #[serde(rename = "localDeviceID", alias = "localDeviceId")]
    pub local_device_id: Identifier,
    pub devices: Vec<DeviceDescriptor>,
    #[serde(default)]
    pub topology: serde_json::Value,
    #[serde(default)]
    pub generation: u64,
}

impl WorkspaceSnapshot {
    pub fn mac(&self) -> Option<&DeviceDescriptor> {
        self.devices
            .iter()
            .find(|device| device.platform.raw_value == "macos")
    }
}

pub fn uuid_wire(value: Uuid) -> String {
    value.hyphenated().to_string().to_uppercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_uses_swift_compatible_raw_values() {
        let device = DeviceDescriptor::linux(Uuid::nil(), "Linux".into(), vec![], vec![]);
        let json = serde_json::to_value(device).unwrap();
        assert_eq!(json["platform"], "linux");
        assert!(
            json["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .all(|value| value.as_str().is_some())
        );
        assert_eq!(json["id"]["rawValue"], Uuid::nil().to_string());
    }
}

#[cfg(test)]
mod wire_casing_tests {
    use super::*;

    /// The pairing hello must decode against the Mac's synthesized Codable:
    /// `deviceID` keeps its capital ID and peer addresses are plain strings.
    #[test]
    fn pairing_descriptor_matches_swift_codable_keys() {
        let device_id = Uuid::from_u128(0x11);
        let device = DeviceDescriptor::linux(
            device_id,
            "dellom".into(),
            vec!["100.77.185.39".into()],
            vec![DisplayDescriptor {
                id: Identifier {
                    raw_value: Uuid::from_u128(0x22),
                },
                device_id: Identifier {
                    raw_value: device_id,
                },
                name: "Linux Desktop".into(),
                frame: DisplayRect {
                    x: 0.0,
                    y: 0.0,
                    width: 1920.0,
                    height: 1080.0,
                },
                scale_factor: 1.0,
                is_main: true,
            }],
        );
        let json = serde_json::to_value(&device).unwrap();
        assert!(json["displays"][0]["deviceID"].is_object(), "{json}");
        assert!(json["peerAddresses"][0].is_string(), "{json}");
        assert_eq!(json["platform"], "linux");
    }
}
