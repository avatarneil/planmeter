//! Desktop-only preferences (range, chart granularity, window size, alerts),
//! kept in `$XDG_STATE_HOME/planmeter/desktop.json`. Host settings such as
//! plan groups and spend limits live in `planmeterd`.

use gtk::glib;
use planmeter::notify::AlertLedger;
use planmeter::range::{Resolution, TimeRange};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UiState {
    pub range: String,
    pub granularities: BTreeMap<String, String>,
    pub width: i32,
    pub height: i32,
    pub maximized: bool,
    pub notifications: bool,
    pub alerts: AlertLedger,
}

impl Default for UiState {
    fn default() -> Self {
        Self {
            range: TimeRange::Today.id().into(),
            granularities: BTreeMap::new(),
            width: 1180,
            height: 820,
            maximized: false,
            notifications: true,
            alerts: AlertLedger::default(),
        }
    }
}

impl UiState {
    fn path() -> PathBuf {
        // XDG state dir; glib's helper needs GLib 2.72 bindings.
        let base = std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| glib::home_dir().join(".local").join("state"));
        base.join("planmeter").join("desktop.json")
    }

    pub fn load() -> Self {
        std::fs::read(Self::path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let path = Self::path();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(bytes) = serde_json::to_vec_pretty(self) {
            // Write then rename, so a crash never leaves half a file.
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
    }

    pub fn range(&self) -> TimeRange {
        TimeRange::from_id(&self.range).unwrap_or(TimeRange::Today)
    }

    pub fn granularity(&self, range: TimeRange) -> Resolution {
        range.resolve_granularity(
            self.granularities
                .get(range.id())
                .and_then(|g| Resolution::parse(g)),
        )
    }
}
