//! End-to-end smoke test for the codebase indexer.
//!
//! Runs against the real Tado source tree + the real downloaded
//! Qwen3-Embedding-0.6B model. `#[ignore]` so it's only invoked
//! manually:
//!
//! ```sh
//! TADO_DOME_TEST_MODEL_DIR=~/Library/Application\ Support/Tado/dome/.bt/models/qwen3-embedding-0.6b \
//! TADO_E2E_PROJECT_ROOT=/Users/miguel/Documents/tado \
//!   cargo test -p bt-core --test code_index_e2e -- --ignored --nocapture
//! ```

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use bt_core::code::{indexer, walker};
use bt_core::error::BtError;
use bt_core::migrations::migrate;
use bt_core::notes::embeddings::{self, Qwen3EmbeddingProvider};
use bt_core::notes::qwen3_runtime::Qwen3Runtime;

#[test]
#[ignore]
fn indexes_real_tado_codebase_with_real_qwen3() {
    let model_dir = match std::env::var("TADO_DOME_TEST_MODEL_DIR") {
        Ok(v) => PathBuf::from(v),
        Err(_) => {
            eprintln!("set TADO_DOME_TEST_MODEL_DIR to run this");
            return;
        }
    };
    let project_root = match std::env::var("TADO_E2E_PROJECT_ROOT") {
        Ok(v) => PathBuf::from(v),
        Err(_) => {
            eprintln!("set TADO_E2E_PROJECT_ROOT to run this");
            return;
        }
    };

    // Boot the real qwen3 runtime.
    let runtime = Qwen3Runtime::load(&model_dir, 1024).expect("load qwen3");
    embeddings::install_runtime(Arc::new(Mutex::new(runtime)));

    // Use a file-backed temp DB so the indexer can re-open
    // connections from inside its closure.
    let db_path = std::env::temp_dir().join(format!(
        "tado-e2e-code-{}.sqlite",
        uuid::Uuid::new_v4()
    ));
    let factory = || -> Result<rusqlite::Connection, BtError> {
        let conn = rusqlite::Connection::open(&db_path)?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        Ok(conn)
    };
    {
        let setup = factory().unwrap();
        migrate(&setup).unwrap();
        bt_core::code::register_project(
            &setup,
            "e2e",
            "Tado",
            &project_root.to_string_lossy(),
            true,
        )
        .unwrap();
    }

    // Walk first to verify the file count is reasonable.
    let walk = walker::walk_project(&project_root);
    eprintln!(
        "walk: files={} skipped_size={} skipped_binary={} skipped_extension={}",
        walk.files.len(),
        walk.skipped_size,
        walk.skipped_binary,
        walk.skipped_extension
    );
    assert!(
        walk.files.len() > 200,
        "expected >200 files in tado source tree, got {}",
        walk.files.len()
    );

    let provider = Qwen3EmbeddingProvider::default();
    assert!(
        provider.is_runtime_loaded(),
        "runtime should be attached after install"
    );

    let progress = indexer::IndexProgress::new("e2e".into());
    let started = std::time::Instant::now();
    let result = indexer::run_full_index(
        factory,
        "e2e",
        &project_root,
        &provider,
        &progress,
        |kind, payload| {
            if kind == "code.index.progress" || kind == "code.index.completed" {
                eprintln!("event {kind}: {payload}");
            }
        },
    )
    .expect("index full");
    let elapsed = started.elapsed();
    eprintln!(
        "indexed {} files / {} chunks / {} bytes in {:.1}s",
        result.files_indexed,
        result.chunks_total,
        result.bytes_total,
        elapsed.as_secs_f64()
    );

    assert!(result.files_indexed > 100);
    assert!(result.chunks_total > result.files_indexed);

    // Verify rows landed and the metadata stamp is qwen3.
    let conn = factory().unwrap();
    let chunk_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM code_chunks WHERE project_id='e2e'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(chunk_count >= result.chunks_total as i64);

    let qwen_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM code_chunks WHERE project_id='e2e' AND embedding_model_id LIKE 'Qwen%'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(qwen_count, chunk_count, "every chunk should be qwen3-stamped");

    let by_lang: Vec<(String, i64)> = {
        let mut stmt = conn
            .prepare("SELECT language, COUNT(*) FROM code_chunks WHERE project_id='e2e' GROUP BY language ORDER BY 2 DESC")
            .unwrap();
        stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect()
    };
    eprintln!("by-language chunk counts:");
    for (lang, n) in &by_lang {
        eprintln!("  {lang}: {n}");
    }
    assert!(by_lang.iter().any(|(lang, _)| lang == "rust"));
    assert!(by_lang.iter().any(|(lang, _)| lang == "swift"));

    // Re-run — every file should be skipped as unchanged. Verifies
    // the SHA-based dedup path holds against real source.
    let progress2 = indexer::IndexProgress::new("e2e".into());
    let result2 = indexer::run_full_index(
        factory,
        "e2e",
        &project_root,
        &provider,
        &progress2,
        |_, _| {},
    )
    .unwrap();
    eprintln!(
        "second run: indexed={} skipped_unchanged={}",
        result2.files_indexed, result2.files_skipped_unchanged
    );
    assert_eq!(result2.files_indexed, 0);
    assert!(result2.files_skipped_unchanged > 100);

    // Cleanup
    let _ = std::fs::remove_file(&db_path);
}

/// Hybrid retrieval smoke test against the just-indexed Tado source.
/// Reuses the same model + project root env vars as the indexer
/// test. Run after `indexes_real_tado_codebase_with_real_qwen3` —
/// this test re-uses a separate temp DB so it does its own walk.
#[test]
#[ignore]
fn hybrid_search_finds_real_code() {
    use bt_core::code::{code_hybrid_search, CodeQuery};

    let model_dir = match std::env::var("TADO_DOME_TEST_MODEL_DIR") {
        Ok(v) => PathBuf::from(v),
        Err(_) => return,
    };
    let project_root = match std::env::var("TADO_E2E_PROJECT_ROOT") {
        Ok(v) => PathBuf::from(v),
        Err(_) => return,
    };

    let runtime = Qwen3Runtime::load(&model_dir, 1024).expect("load qwen3");
    embeddings::install_runtime(Arc::new(Mutex::new(runtime)));

    let db_path = std::env::temp_dir().join(format!(
        "tado-e2e-search-{}.sqlite",
        uuid::Uuid::new_v4()
    ));
    let factory = || -> Result<rusqlite::Connection, BtError> {
        let conn = rusqlite::Connection::open(&db_path)?;
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        Ok(conn)
    };
    {
        let setup = factory().unwrap();
        migrate(&setup).unwrap();
        bt_core::code::register_project(
            &setup,
            "search",
            "Tado",
            &project_root.to_string_lossy(),
            true,
        )
        .unwrap();
    }

    let provider = Qwen3EmbeddingProvider::default();
    let progress = indexer::IndexProgress::new("search".into());
    indexer::run_full_index(
        factory,
        "search",
        &project_root,
        &provider,
        &progress,
        |_, _| {},
    )
    .expect("index");

    let conn = factory().unwrap();

    // Query 1: identifier-style match. Lexical lane should find it
    // immediately even before vector kicks in.
    let q1_pids = vec!["search".to_string()];
    let mut q1 = CodeQuery::new("spawn_session");
    q1.project_ids = Some(&q1_pids);
    q1.limit = 10;
    let hits1 = code_hybrid_search(&conn, &q1, &provider).expect("search 1");
    eprintln!("query \"spawn_session\" -> {} hits", hits1.len());
    for h in hits1.iter().take(5) {
        eprintln!(
            "  {}:{} kind={:?} qn={:?} v={:?} l={:?} c={:.4}",
            h.repo_path,
            h.start_line,
            h.node_kind,
            h.qualified_name,
            h.vector_score,
            h.lexical_score,
            h.combined_score
        );
    }
    assert!(!hits1.is_empty(), "spawn_session should match something");

    // Query 2: pure-semantic — phrase that isn't likely to appear
    // verbatim. The vector lane should carry the recall.
    let q2_pids = vec!["search".to_string()];
    let mut q2 = CodeQuery::new("where do we spawn the PTY for a terminal session");
    q2.project_ids = Some(&q2_pids);
    q2.limit = 10;
    let hits2 = code_hybrid_search(&conn, &q2, &provider).expect("search 2");
    eprintln!("query \"where do we spawn the PTY...\" -> {} hits", hits2.len());
    for h in hits2.iter().take(5) {
        eprintln!(
            "  {}:{} kind={:?} qn={:?} v={:?} l={:?} c={:.4}",
            h.repo_path,
            h.start_line,
            h.node_kind,
            h.qualified_name,
            h.vector_score,
            h.lexical_score,
            h.combined_score
        );
    }
    assert!(!hits2.is_empty(), "PTY query should match something");
    let top_path_q2 = &hits2[0].repo_path;
    eprintln!("top hit for PTY query: {top_path_q2}");

    let _ = std::fs::remove_file(&db_path);
}
