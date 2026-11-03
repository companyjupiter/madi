//! Read-only input-device discovery; does not open a stream or request permission.
use serde::Serialize;

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct InputDevice {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InputDevices {
    pub supported: bool,
    pub devices: Vec<InputDevice>,
    pub default_input_id: Option<String>,
}

#[cfg(target_os = "macos")]
mod macos;

pub fn snapshot() -> InputDevices {
    #[cfg(target_os = "macos")]
    return macos::snapshot();

    #[cfg(not(target_os = "macos"))]
    InputDevices {
        supported: false,
        devices: Vec::new(),
        default_input_id: None,
    }
}
