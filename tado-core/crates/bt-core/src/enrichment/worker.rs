//! tokio worker pool that drains `pending_enrichment`.
//!
//! One worker per `EnrichmentKind`. Each worker:
//! 1. Sleeps `poll_interval` (default 2s).
//! 2. Calls [`crate::enrichment::claim_batch`] up to `batch_size` jobs.
//! 3. Dispatches each job to the matching enricher fn.
//! 4. Marks each job done/failed.
//!
//! Strict no-watchdog discipline: a panic inside an enricher would
//! tear down only that worker (tokio's `JoinHandle` propagates the
//! panic at shutdown). We don't restart on panic — the panic is the
//! signal. Recoverable errors (`BtError`) get stashed in
//! `pending_enrichment.last_error` and the worker continues.

use crate::enrichment::{self, claim_batch, deduper, decayer, extractor, linker};
use crate::enrichment::{EnrichmentJob, EnrichmentKind};
use crate::error::BtError;
use crate::service::CoreService;
use std::time::Duration;
use tokio::task::JoinHandle;
use tokio::time::{interval, MissedTickBehavior};

/// Knobs for the worker pool. Defaults are calibrated for laptop
/// idle-priority — small batches, low cadence, single thread per kind.
#[derive(Debug, Clone)]
pub struct EnrichmentSettings {
    pub poll_interval: Duration,
    pub decay_interval: Duration,
    pub batch_size: usize,
}

impl Default for EnrichmentSettings {
    fn default() -> Self {
        Self {
            poll_interval: Duration::from_secs(2),
            decay_interval: Duration::from_secs(900), // 15 min
            batch_size: 16,
        }
    }
}

/// Handles for the spawned tokio tasks. Drop them to abort.
pub struct EnrichmentTaskHandles {
    pub extractor: JoinHandle<()>,
    pub linker: JoinHandle<()>,
    pub deduper: JoinHandle<()>,
    pub decayer: JoinHandle<()>,
}

impl EnrichmentTaskHandles {
    pub fn abort_all(&self) {
        self.extractor.abort();
        self.linker.abort();
        self.deduper.abort();
        self.decayer.abort();
    }
}

/// Spawn the four enrichment workers as tokio tasks. Each task owns a
/// `CoreService` clone and re-opens the DB on every tick — fine
/// because `open_conn` is cheap (rusqlite's bundled driver) and keeps
/// us from holding a long-lived connection that could deadlock with
/// the scheduler.
pub fn spawn_workers(service: CoreService, settings: EnrichmentSettings) -> EnrichmentTaskHandles {
    let extractor = tokio::spawn(run_loop(
        service.clone(),
        settings.clone(),
        EnrichmentKind::Extract,
    ));
    let linker = tokio::spawn(run_loop(
        service.clone(),
        settings.clone(),
        EnrichmentKind::Link,
    ));
    let deduper = tokio::spawn(run_loop(
        service.clone(),
        settings.clone(),
        EnrichmentKind::Dedupe,
    ));
    let decayer = tokio::spawn(run_decayer(service, settings));
    EnrichmentTaskHandles {
        extractor,
        linker,
        deduper,
        decayer,
    }
}

async fn run_loop(service: CoreService, settings: EnrichmentSettings, kind: EnrichmentKind) {
    let mut ticker = interval(settings.poll_interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        ticker.tick().await;
        if let Err(err) = drain_once(&service, kind, settings.batch_size) {
            eprintln!("bt-core enrichment ({}) tick error: {}", kind.as_str(), err);
        }
    }
}

async fn run_decayer(service: CoreService, settings: EnrichmentSettings) {
    let mut ticker = interval(settings.decay_interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        ticker.tick().await;
        if let Err(err) = drain_once(&service, EnrichmentKind::Decay, settings.batch_size) {
            eprintln!("bt-core enrichment (decay) tick error: {}", err);
        }
        // Even if the queue is empty, run a sweep pass — the decayer's
        // job is mostly TTL/retention scans, not queue-driven.
        if let Err(err) = run_decayer_sweep(&service) {
            eprintln!("bt-core decayer sweep error: {}", err);
        }
    }
}

fn run_decayer_sweep(service: &CoreService) -> Result<(), BtError> {
    let conn = service.open_conn()?;
    let synthetic = EnrichmentJob {
        job_id: "decay_sweep".into(),
        target_kind: "system".into(),
        target_id: "all".into(),
        enrichment_kind: EnrichmentKind::Decay,
        project_id: None,
        attempts: 1,
        payload: serde_json::Value::Null,
    };
    let _ = decayer::run(&conn, &synthetic)?;
    Ok(())
}

fn drain_once(
    service: &CoreService,
    kind: EnrichmentKind,
    batch: usize,
) -> Result<usize, BtError> {
    let conn = service.open_conn()?;
    let jobs = claim_batch(&conn, kind, batch)?;
    let n = jobs.len();
    for job in jobs {
        // Wrap the per-job dispatch in `catch_unwind` so a single
        // poisoned input — bad markdown, malformed UUID, OOM in the
        // hashing crate — fails *that job* instead of taking down the
        // worker until the daemon restarts. We deliberately do NOT
        // restart the panicked task: the failed row stays in
        // `pending_enrichment` with a `panic: …` `last_error`, and
        // future enqueues for the same target (different job_id)
        // proceed normally. Operators can `dome-eval explain` the
        // panic'd row from logs.
        let job_for_panic = job.clone();
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| match kind {
            EnrichmentKind::Extract | EnrichmentKind::BackfillExtract => {
                extractor::run(&conn, &job).map(|_| ())
            }
            EnrichmentKind::Link => linker::run(&conn, &job).map(|_| ()),
            EnrichmentKind::Dedupe => deduper::run(&conn, &job).map(|_| ()),
            EnrichmentKind::Decay => decayer::run(&conn, &job).map(|_| ()),
        }));
        match outcome {
            Ok(Ok(())) => enrichment::mark_done(&conn, &job_for_panic.job_id)?,
            Ok(Err(err)) => enrichment::mark_failed(
                &conn,
                &job_for_panic.job_id,
                &truncate_error(err.to_string()),
            )?,
            Err(panic_payload) => {
                let msg = if let Some(s) = panic_payload.downcast_ref::<&str>() {
                    format!("panic: {s}")
                } else if let Some(s) = panic_payload.downcast_ref::<String>() {
                    format!("panic: {s}")
                } else {
                    "panic: <non-string payload>".to_string()
                };
                eprintln!(
                    "bt-core enrichment ({}) panic on job {}: {}",
                    kind.as_str(),
                    job_for_panic.job_id,
                    msg
                );
                enrichment::mark_failed(&conn, &job_for_panic.job_id, &truncate_error(msg))?;
            }
        }
    }
    Ok(n)
}

/// Cap the error string at 2 KB so a runaway diagnostic doesn't
/// bloat `pending_enrichment.last_error` and slow future scans.
fn truncate_error(s: String) -> String {
    const LIMIT: usize = 2048;
    if s.len() <= LIMIT {
        s
    } else {
        let mut t: String = s.chars().take(LIMIT).collect();
        t.push_str(" …<truncated>");
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_defaults_are_sensible() {
        let s = EnrichmentSettings::default();
        assert_eq!(s.poll_interval, Duration::from_secs(2));
        assert_eq!(s.decay_interval, Duration::from_secs(900));
        assert_eq!(s.batch_size, 16);
    }

    #[test]
    fn settings_clone_preserves_values() {
        let a = EnrichmentSettings {
            poll_interval: Duration::from_millis(100),
            decay_interval: Duration::from_secs(60),
            batch_size: 8,
        };
        let b = a.clone();
        assert_eq!(a.poll_interval, b.poll_interval);
        assert_eq!(a.batch_size, b.batch_size);
    }
}
