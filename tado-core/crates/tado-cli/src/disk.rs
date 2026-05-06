//! Read-only access to on-disk Tado state. Lets read-only CLI
//! verbs (`projects list`, `eternal status`, `eternal crafted`,
//! etc.) answer without an IPC round-trip into the running app.
//!
//! The canonical store is the running app's SwiftData; these
//! files are mirrored copies maintained by Swift services
//! (`ProjectIndexService`, `EternalService`, `DispatchPlanService`).
//! The CLI side never writes here — disk reads are strictly
//! advisory and may lag SwiftData by one save cycle.

use serde::Deserialize;
use std::path::{Path, PathBuf};

use tado_settings::SettingsPaths;

#[derive(Deserialize, Debug, Clone)]
pub struct ProjectIndexEntry {
    pub id: String,
    pub name: String,
    #[serde(rename = "rootPath")]
    pub root_path: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
}

/// Path to the active storage root resolved through the fixed
/// macOS locator file, exactly mirroring Swift's `StorePaths.root`.
fn storage_root() -> PathBuf {
    SettingsPaths::macos_default()
        .map(|p| p.app_support)
        .unwrap_or_else(|| PathBuf::from("/tmp/tado-cli-fallback"))
}

/// Path to the projects index file: `<storage-root>/projects.json`.
pub fn projects_index_path() -> PathBuf {
    storage_root().join("projects.json")
}

/// Read and decode the projects index. Returns an empty Vec if
/// the file is missing — matches the "no projects yet" case
/// without surfacing a hard error to the user.
pub fn read_projects_index() -> Vec<ProjectIndexEntry> {
    let path = projects_index_path();
    let raw = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(_) => return Vec::new(),
    };
    serde_json::from_slice(&raw).unwrap_or_default()
}

/// Resolve a project name (case-insensitive). Tries exact match
/// first, falls back to substring. None on no match; first
/// candidate on multiple matches.
pub fn resolve_project(name: &str) -> Option<ProjectIndexEntry> {
    let entries = read_projects_index();
    let lower = name.to_lowercase();
    if let Some(exact) = entries.iter().find(|e| e.name.to_lowercase() == lower) {
        return Some(exact.clone());
    }
    let substring = entries.iter().find(|e| e.name.to_lowercase().contains(&lower));
    substring.cloned()
}

/// On-disk path to a run's directory:
/// `<project-root>/.tado/eternal/runs/<run-id>/` for Eternal,
/// `<project-root>/.tado/dispatch/runs/<run-id>/` for Dispatch.
pub fn eternal_run_dir(project_root: &Path, run_id: &str) -> PathBuf {
    project_root.join(".tado/eternal/runs").join(run_id)
}

pub fn dispatch_run_dir(project_root: &Path, run_id: &str) -> PathBuf {
    project_root.join(".tado/dispatch/runs").join(run_id)
}

/// Read `crafted.md` if it exists.
pub fn read_crafted(run_dir: &Path) -> Option<String> {
    std::fs::read_to_string(run_dir.join("crafted.md")).ok()
}
