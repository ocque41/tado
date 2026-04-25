//! Canonical settings path resolver.
//!
//! Centralises the `~/Library/Application Support/Tado/` layout
//! Swift's `StorePaths` currently hardcodes, plus the per-project
//! `<project>/.tado/` layout.
//!
//! Most helpers are pure path math. `macos_default()` also reads the
//! fixed `storage-location.json` locator so external tools follow the
//! same active storage root as the Swift app.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StorageLocationRecord {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    pub active_root: Option<PathBuf>,
    pub pending_root: Option<PathBuf>,
    pub last_move_error: Option<String>,
    pub updated_at: Option<serde_json::Value>,
}

fn default_schema_version() -> u32 {
    1
}

/// Known locations for one Tado "installation".
#[derive(Debug, Clone)]
pub struct SettingsPaths {
    /// Root of the user-level Application Support tree. Usually
    /// `~/Library/Application Support/Tado` on macOS; overridable
    /// for tests or alternative layouts.
    pub app_support: PathBuf,
}

impl SettingsPaths {
    pub const LOCATOR_FILE_NAME: &'static str = "storage-location.json";

    /// Fixed macOS root that always contains the storage locator. The
    /// actual active store may move elsewhere; this path remains the
    /// discovery point.
    pub fn macos_default_root() -> Option<PathBuf> {
        if let Some(root) = std::env::var_os("TADO_STORAGE_DEFAULT_ROOT") {
            return Some(PathBuf::from(root));
        }
        let home = std::env::var_os("HOME")?;
        Some(PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("Tado"))
    }

    pub fn locator_file_at(default_root: impl AsRef<Path>) -> PathBuf {
        default_root.as_ref().join(Self::LOCATOR_FILE_NAME)
    }

    /// Resolve the active storage root from the fixed locator file.
    /// Pending moves do not affect callers until the app flips
    /// `activeRoot` on restart.
    pub fn macos_default() -> Option<Self> {
        let default_root = Self::macos_default_root()?;
        let root = Self::active_root_from_locator(&default_root).unwrap_or(default_root);
        Some(Self { app_support: root })
    }

    pub fn active_root_from_locator(default_root: impl AsRef<Path>) -> Option<PathBuf> {
        let default_root = default_root.as_ref();
        let locator = Self::locator_file_at(default_root);
        let raw = std::fs::read_to_string(locator).ok()?;
        let parsed: StorageLocationRecord = serde_json::from_str(&raw).ok()?;
        parsed.active_root.filter(|path| !path.as_os_str().is_empty())
    }

    /// Explicit root. Intended for tests.
    pub fn at(root: impl Into<PathBuf>) -> Self {
        Self {
            app_support: root.into(),
        }
    }

    // ── User-scoped paths ────────────────────────────────────

    pub fn settings_dir(&self) -> PathBuf {
        self.app_support.join("settings")
    }

    pub fn global_json(&self) -> PathBuf {
        self.settings_dir().join("global.json")
    }

    pub fn memory_dir(&self) -> PathBuf {
        self.app_support.join("memory")
    }

    pub fn user_memory_md(&self) -> PathBuf {
        self.memory_dir().join("user.md")
    }

    pub fn user_memory_json(&self) -> PathBuf {
        self.memory_dir().join("user.json")
    }

    pub fn events_dir(&self) -> PathBuf {
        self.app_support.join("events")
    }

    pub fn current_events(&self) -> PathBuf {
        self.events_dir().join("current.ndjson")
    }

    pub fn events_archive(&self) -> PathBuf {
        self.events_dir().join("archive")
    }

    pub fn backups_dir(&self) -> PathBuf {
        self.app_support.join("backups")
    }

    pub fn cache_dir(&self) -> PathBuf {
        self.app_support.join("cache")
    }

    pub fn version_file(&self) -> PathBuf {
        self.app_support.join("version")
    }

    // ── Per-project paths ───────────────────────────────────

    /// Root of the per-project `.tado/` directory, given the
    /// project's own root. No I/O — purely path math.
    pub fn project_dir(project_root: impl AsRef<Path>) -> PathBuf {
        project_root.as_ref().join(".tado")
    }

    pub fn project_config_json(project_root: impl AsRef<Path>) -> PathBuf {
        Self::project_dir(project_root).join("config.json")
    }

    pub fn project_local_json(project_root: impl AsRef<Path>) -> PathBuf {
        Self::project_dir(project_root).join("local.json")
    }

    pub fn project_memory_dir(project_root: impl AsRef<Path>) -> PathBuf {
        Self::project_dir(project_root).join("memory")
    }

    pub fn project_memory_md(project_root: impl AsRef<Path>) -> PathBuf {
        Self::project_memory_dir(project_root).join("project.md")
    }

    pub fn project_notes_dir(project_root: impl AsRef<Path>) -> PathBuf {
        Self::project_memory_dir(project_root).join("notes")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macos_default_uses_home() {
        std::env::set_var("HOME", "/tmp/fake-home");
        std::env::remove_var("TADO_STORAGE_DEFAULT_ROOT");
        let p = SettingsPaths::macos_default().unwrap();
        assert_eq!(
            p.app_support,
            PathBuf::from("/tmp/fake-home/Library/Application Support/Tado")
        );
    }

    #[test]
    fn locator_active_root_is_read() {
        let dir = tempfile::tempdir().unwrap();
        let default_root = dir.path().join("DefaultTado");
        std::fs::create_dir_all(&default_root).unwrap();
        std::fs::write(
            SettingsPaths::locator_file_at(&default_root),
            r#"{"schemaVersion":1,"activeRoot":"/tmp/custom-tado"}"#,
        )
        .unwrap();
        let root = SettingsPaths::active_root_from_locator(&default_root).unwrap();
        assert_eq!(root, PathBuf::from("/tmp/custom-tado"));
    }

    #[test]
    fn pending_root_does_not_change_active_root() {
        let dir = tempfile::tempdir().unwrap();
        let default_root = dir.path().join("DefaultTado");
        std::fs::create_dir_all(&default_root).unwrap();
        std::fs::write(
            SettingsPaths::locator_file_at(&default_root),
            r#"{"schemaVersion":1,"pendingRoot":"/tmp/new-tado"}"#,
        )
        .unwrap();
        assert!(SettingsPaths::active_root_from_locator(&default_root).is_none());
    }

    #[test]
    fn user_paths_compose_under_app_support() {
        let p = SettingsPaths::at("/tmp/test-app-support");
        assert_eq!(
            p.global_json(),
            PathBuf::from("/tmp/test-app-support/settings/global.json")
        );
        assert_eq!(
            p.user_memory_md(),
            PathBuf::from("/tmp/test-app-support/memory/user.md")
        );
        assert_eq!(
            p.current_events(),
            PathBuf::from("/tmp/test-app-support/events/current.ndjson")
        );
        assert_eq!(
            p.backups_dir(),
            PathBuf::from("/tmp/test-app-support/backups")
        );
    }

    #[test]
    fn project_paths_compose_under_project_root() {
        assert_eq!(
            SettingsPaths::project_config_json("/proj"),
            PathBuf::from("/proj/.tado/config.json")
        );
        assert_eq!(
            SettingsPaths::project_local_json("/proj"),
            PathBuf::from("/proj/.tado/local.json")
        );
        assert_eq!(
            SettingsPaths::project_memory_md("/proj"),
            PathBuf::from("/proj/.tado/memory/project.md")
        );
        assert_eq!(
            SettingsPaths::project_notes_dir("/proj"),
            PathBuf::from("/proj/.tado/memory/notes")
        );
    }
}
