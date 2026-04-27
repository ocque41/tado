//! Integration test: load `tests/corpus/baseline.yaml`, run it through
//! the production retrieval path, assert the v0.10 baseline thresholds.
//!
//! This is the CI gate that every later phase touching retrieval has to
//! keep green. If the heuristic rerank or sqlite-vec swap regresses
//! mean P@5 below 0.35, this test fails the build.

use dome_eval::{corpus::run_corpus, Corpus};
use std::path::PathBuf;

fn corpus_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/corpus/baseline.yaml")
}

#[test]
fn baseline_corpus_meets_v0_10_thresholds() {
    let corpus = Corpus::from_path(&corpus_path()).expect("loading baseline corpus");
    let report = run_corpus(&corpus).expect("running baseline corpus");

    // Print the one-line summary even on success — useful in CI logs
    // for tracking metric drift over time.
    println!("{}", report.one_line());

    assert!(
        report.passed,
        "baseline corpus regressed: {:#?}",
        report.failures
    );

    // Sanity: with 30 cases, n_cases must match.
    assert_eq!(report.aggregate.n_cases, 30);
}

#[test]
fn baseline_corpus_validates_structurally() {
    let corpus = Corpus::from_path(&corpus_path()).expect("loading baseline corpus");
    assert!(!corpus.docs.is_empty());
    assert!(!corpus.cases.is_empty());

    // Every case's relevant_doc_ids must reference a doc that exists,
    // otherwise the corpus is silently broken.
    let doc_ids: std::collections::HashSet<&str> =
        corpus.docs.iter().map(|d| d.id.as_str()).collect();
    for case in &corpus.cases {
        for id in &case.relevant_doc_ids {
            assert!(
                doc_ids.contains(id.as_str()),
                "case {} references unknown doc id {}",
                case.id,
                id
            );
        }
    }
}
