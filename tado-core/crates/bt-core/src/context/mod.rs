//! Phase 4 — context packs v2.
//!
//! The Swift `DomeContextPreamble` was the v0.10 entry point: every
//! non-Eternal Tado spawn called it to build a `<!-- tado:context:begin
//! -->` block. v0.13 ports the composer to Rust ([`spawn_pack`]) so:
//!
//! 1. The hot path can hit a cache (`context_packs`) instead of
//!    re-querying recent notes on every spawn.
//! 2. The same composer is reachable from non-Swift callers (CLI,
//!    headless tests, tooling).
//! 3. Byte-equivalence tests can pin the contract — every bootstrapped
//!    project relies on the `<!-- tado:context:begin -->` /
//!    `<!-- tado:context:end -->` markers + section structure.
//!
//! Strict invariant: [`compose_spawn_preamble`] is byte-identical to
//! the Swift composer's output for the same input. The Swift side
//! delegates here once `dome.context_packs_v2` flips on; before then
//! both run in shadow and the integration test compares.

pub mod relative;
pub mod spawn_pack;

pub use spawn_pack::{
    compose_spawn_preamble, retrieval_contract_fragment, RecentNote, SpawnPackContext,
    SPAWN_PACK_MAX_CHARS,
};
