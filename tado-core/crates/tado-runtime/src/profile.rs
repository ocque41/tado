use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};
use tado_settings::SettingsPaths;

pub const DEFAULT_PROFILE: &str = "cli";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfilePaths {
    pub profile: String,
    pub storage_root: PathBuf,
    pub runtime_root: PathBuf,
    pub profile_root: PathBuf,
    pub logs_dir: PathBuf,
    pub db_path: PathBuf,
    pub socket_root: PathBuf,
    pub socket_path: PathBuf,
}

pub fn profile_from_env(explicit: Option<String>) -> String {
    explicit
        .or_else(|| std::env::var("TADO_PROFILE").ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_PROFILE.to_string())
}

impl ProfilePaths {
    pub fn resolve(profile: &str) -> Result<Self> {
        let profile = sanitize_profile(profile)?;
        let storage_root = if let Some(root) = std::env::var_os("TADO_RUNTIME_ROOT") {
            PathBuf::from(root)
        } else if let Some(root) = std::env::var_os("TADO_STORAGE_ROOT") {
            PathBuf::from(root).join("runtime")
        } else {
            SettingsPaths::macos_default()
                .ok_or_else(|| anyhow!("could not resolve Tado storage root"))?
                .app_support
                .join("runtime")
        };
        let socket_root = std::env::var_os("TADO_RUNTIME_SOCKET_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(default_socket_root);
        Ok(Self::new(profile, storage_root, socket_root))
    }

    pub fn new(
        profile: impl Into<String>,
        runtime_root: impl Into<PathBuf>,
        socket_root: impl Into<PathBuf>,
    ) -> Self {
        let profile = profile.into();
        let runtime_root = runtime_root.into();
        let socket_root = socket_root.into();
        let profile_root = runtime_root.join("profiles").join(&profile);
        let logs_dir = profile_root.join("logs");
        let db_path = profile_root.join("runtime.sqlite");
        let socket_path = std::env::var_os("TADO_RUNTIME_SOCKET")
            .map(PathBuf::from)
            .unwrap_or_else(|| socket_root.join(format!("{profile}.sock")));
        Self {
            storage_root: runtime_root.clone(),
            runtime_root,
            profile,
            profile_root,
            logs_dir,
            db_path,
            socket_root,
            socket_path,
        }
    }

    pub fn create_dirs(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.profile_root)?;
        std::fs::create_dir_all(&self.logs_dir)?;
        std::fs::create_dir_all(&self.socket_root)?;
        Ok(())
    }

    pub fn log_path(&self) -> PathBuf {
        self.logs_dir.join("tadod.log")
    }
}

pub fn sanitize_profile(input: &str) -> Result<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Ok(DEFAULT_PROFILE.to_string());
    }
    let mut out = String::with_capacity(trimmed.len());
    for ch in trimmed.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.') {
            out.push(ch);
        } else {
            out.push('-');
        }
    }
    let out = out.trim_matches(['-', '.']).to_string();
    if out.is_empty() {
        Err(anyhow!("profile name has no usable characters"))
    } else {
        Ok(out)
    }
}

fn default_socket_root() -> PathBuf {
    let uid = unsafe { libc::geteuid() };
    std::env::temp_dir().join(format!("tado-runtime-{uid}"))
}

pub fn remove_stale_socket(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_profile_for_paths() {
        assert_eq!(sanitize_profile("cli").unwrap(), "cli");
        assert_eq!(sanitize_profile("team/main").unwrap(), "team-main");
        assert_eq!(
            sanitize_profile("  ...  ").unwrap_err().to_string(),
            "profile name has no usable characters"
        );
    }

    #[test]
    fn builds_profile_isolated_paths() {
        let paths = ProfilePaths::new("cli", "/tmp/tado-runtime", "/tmp/tado-sockets");
        assert_eq!(
            paths.db_path,
            PathBuf::from("/tmp/tado-runtime/profiles/cli/runtime.sqlite")
        );
        assert_eq!(
            paths.socket_path,
            PathBuf::from("/tmp/tado-sockets/cli.sock")
        );
    }
}
