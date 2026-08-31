pub mod clipboard;
pub mod config;
pub mod files;
pub mod input;
pub mod model;
pub mod pairing;
pub mod protocol;
pub mod receiver;
pub mod secure;
pub mod status;

pub const CONTROL_PORT: u16 = 61_338;
pub const FILE_TRANSFER_PORT: u16 = 61_340;
pub const POINTER_PORT: u16 = 61_341;
pub const CLIPBOARD_PORT: u16 = 61_342;
pub const PAIRING_PORT: u16 = 61_337;
