//! The five config scopes.
//!
//! Matches Swift's per-scope JSON files:
//!
//! | Scope              | On-disk location                                  |
//! |--------------------|---------------------------------------------------|
//! | `Runtime`          | never persisted (in-memory overlay)               |
//! | `ProjectLocal`     | `<project>/.tado/local.json`                      |
//! | `ProjectShared`    | `<project>/.tado/config.json`                     |
//! | `UserGlobal`       | `~/Library/Application Support/Tado/settings/global.json` |
//! | `BuiltInDefault`   | compiled-in literal                               |
//!
//! Precedence from highest to lowest is `Runtime > ProjectLocal >
//! ProjectShared > UserGlobal > BuiltInDefault` — the first scope
//! to provide a value wins.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Scope {
    /// In-memory runtime overlay (CLI flag, env var, IPC command).
    /// Wins above everything else. Never persisted.
    Runtime,
    /// Project-local private overrides. Typically gitignored.
    ProjectLocal,
    /// Project-shared config, intended to be committed.
    ProjectShared,
    /// User-level defaults under Application Support.
    UserGlobal,
    /// Compiled-in defaults. The floor of the hierarchy.
    BuiltInDefault,
}

impl Scope {
    /// All scopes in precedence order (highest wins first).
    pub fn precedence() -> [Scope; 5] {
        [
            Scope::Runtime,
            Scope::ProjectLocal,
            Scope::ProjectShared,
            Scope::UserGlobal,
            Scope::BuiltInDefault,
        ]
    }

    /// Whether this scope is backed by a JSON file on disk.
    pub fn is_persisted(self) -> bool {
        !matches!(self, Scope::Runtime | Scope::BuiltInDefault)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn precedence_has_five_unique_scopes() {
        let scopes = Scope::precedence();
        let unique: std::collections::HashSet<_> = scopes.iter().copied().collect();
        assert_eq!(scopes.len(), 5);
        assert_eq!(unique.len(), 5);
    }

    #[test]
    fn runtime_is_highest() {
        assert_eq!(Scope::precedence()[0], Scope::Runtime);
    }

    #[test]
    fn built_in_default_is_lowest() {
        assert_eq!(Scope::precedence()[4], Scope::BuiltInDefault);
    }

    #[test]
    fn persisted_flag_matches_spec() {
        assert!(!Scope::Runtime.is_persisted());
        assert!(!Scope::BuiltInDefault.is_persisted());
        assert!(Scope::ProjectLocal.is_persisted());
        assert!(Scope::ProjectShared.is_persisted());
        assert!(Scope::UserGlobal.is_persisted());
    }
}
