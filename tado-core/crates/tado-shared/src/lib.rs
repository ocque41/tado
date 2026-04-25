//! `tado-shared` — workspace-wide helpers used by every other Tado
//! Rust crate.
//!
//! ## Status
//!
//! Empty on workspace creation. This crate exists now so:
//!
//! 1. Future crates (`tado-ipc`, `tado-settings`, `tado-extensions`)
//!    have an obvious place to drop primitives they share instead of
//!    each reinventing them.
//! 2. The workspace has more than one member from day one — keeps
//!    the `[workspace]` Cargo.toml honest and prevents a later
//!    "upgrade this single-crate workspace" commit that could break
//!    `Package.swift` link paths.
//!
//! As later phases extract FFI helpers, error types, or ID newtypes
//! from `tado-terminal`, they land here.

// Intentionally empty. Re-exports arrive as real primitives migrate
// in; for now the crate is a shape-only placeholder so the workspace
// starts with two members.
