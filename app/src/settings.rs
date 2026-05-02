// Per-monitor-config persistence for window state (zoom + size + position).
//
// Lives at ``~/.config/turbokod/window.json`` next to the Mojo side's
// ``config.json``. Kept in a separate file so the two languages can save
// independently without one clobbering the other's keys.
//
// The persisted state is keyed by a *fingerprint* of the currently
// connected monitors (sorted by name + size + position). Plugging or
// unplugging a display changes the fingerprint, at which point the host
// reloads the config for the new key — falling back to defaults when no
// entry exists yet, so a brand new monitor combination behaves the same
// as a first launch.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use winit::event_loop::ActiveEventLoop;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct WindowState {
    pub scale: u32,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default)]
    pub monitor_configs: BTreeMap<String, WindowState>,
}

fn settings_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join(".config")
            .join("turbokod")
            .join("window.json"),
    )
}

impl Settings {
    pub fn load() -> Self {
        let Some(path) = settings_path() else {
            return Self::default();
        };
        let Ok(text) = fs::read_to_string(&path) else {
            return Self::default();
        };
        serde_json::from_str(&text).unwrap_or_default()
    }

    pub fn save(&self) {
        let Some(path) = settings_path() else { return };
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let Ok(text) = serde_json::to_string_pretty(self) else { return };
        let _ = fs::write(&path, text);
    }

    pub fn get(&self, fingerprint: &str) -> Option<WindowState> {
        self.monitor_configs.get(fingerprint).copied()
    }

    pub fn put(&mut self, fingerprint: &str, state: WindowState) {
        self.monitor_configs.insert(fingerprint.to_string(), state);
    }
}

// Stable fingerprint for the current monitor topology. Sorting makes the
// key independent of enumeration order. Changes when a monitor is added,
// removed, or repositioned in the OS's display arrangement — exactly the
// trigger we want for reloading saved geometry.
pub fn monitor_fingerprint(el: &ActiveEventLoop) -> String {
    let mut entries: Vec<String> = el
        .available_monitors()
        .map(|m| {
            let name = m.name().unwrap_or_default();
            let size = m.size();
            let pos = m.position();
            format!(
                "{}|{}x{}+{}+{}",
                name, size.width, size.height, pos.x, pos.y
            )
        })
        .collect();
    entries.sort();
    entries.join(";")
}
