//! Microbenchmarks for the Rust terminal core. Run with `cargo bench`.
//!
//! Two benches:
//!   * `grid_write_throughput` — feeds ~1 MB of synthetic VT output (mix of
//!     printable text, SGR color toggles, line wraps, erases) through the
//!     parser → performer → grid pipeline for a 100×40 grid. Reports the
//!     time to ingest the full buffer; Criterion's throughput mode prints
//!     MiB/s alongside.
//!   * `snapshot_dirty_latency` — after one hot-loop warmup, measures the
//!     cost of `take_dirty()` when exactly one row is dirty (the common
//!     per-frame case when an agent writes a single prompt line).
//!
//! These numbers bound the Rust-side per-tile cost. For an end-to-end
//! "100 tiles idle CPU" target, see `bench/BENCH.md` — that's a manual
//! macro-benchmark of the whole Metal + Swift path.

use criterion::{black_box, criterion_group, criterion_main, Criterion, Throughput};
use tado_core::grid::Grid;
use tado_core::performer::GridPerformer;
use vte::Parser;

/// Deterministic ~1 MB byte buffer mixing printable text, SGR color
/// toggles (31/32/0), explicit newlines, and an occasional full-screen
/// erase (`CSI 2 J`). Shape is chosen to look plausibly like real agent
/// output so the grid's hot paths (put_char, linefeed, scroll_up,
/// erase_display, SGR apply) all get exercised.
fn synthetic_vt_payload(target_bytes: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(target_bytes + 64);
    let mut i: usize = 0;
    while out.len() < target_bytes {
        // 40 chars of printable text
        for _ in 0..40 {
            let ch = b'A' + ((i % 26) as u8);
            out.push(ch);
            i = i.wrapping_add(1);
        }
        // SGR toggle
        out.extend_from_slice(b"\x1b[31m");
        // More text
        for _ in 0..20 {
            let ch = b'a' + ((i % 26) as u8);
            out.push(ch);
            i = i.wrapping_add(1);
        }
        out.extend_from_slice(b"\x1b[0m\r\n");
        // Every ~4k, erase the screen to exercise scroll_up/erase.
        if i % 4000 < 60 {
            out.extend_from_slice(b"\x1b[2J");
        }
    }
    out.truncate(target_bytes);
    out
}

fn bench_grid_write_throughput(c: &mut Criterion) {
    let data = synthetic_vt_payload(1_048_576); // 1 MiB
    let mut group = c.benchmark_group("grid_write_throughput");
    group.throughput(Throughput::Bytes(data.len() as u64));
    group.bench_function("vt_1mib_into_100x40_grid", |b| {
        b.iter(|| {
            let mut grid = Grid::new(100, 40);
            let mut parser = Parser::new();
            let mut events = Vec::new();
            let mut perf = GridPerformer::new(&mut grid, &mut events);
            for &byte in black_box(&data) {
                parser.advance(&mut perf, byte);
            }
            black_box(&grid.cells[0]); // prevent dead-code elim
        });
    });
    group.finish();
}

fn bench_snapshot_dirty_latency(c: &mut Criterion) {
    c.bench_function("snapshot_dirty_one_row", |b| {
        let mut grid = Grid::new(100, 40);
        // Warm up: fill the grid then clear dirty so steady-state mirrors
        // a live session partway through.
        for _ in 0..20 {
            grid.linefeed();
            for _ in 0..60 {
                grid.put_char('x');
            }
        }
        let _ = grid.take_dirty();

        b.iter(|| {
            // Touch one row, then drain — mirrors what the renderer does
            // every frame when the agent writes a single prompt line.
            grid.put_char('a');
            black_box(grid.take_dirty())
        });
    });
}

criterion_group!(benches, bench_grid_write_throughput, bench_snapshot_dirty_latency);
criterion_main!(benches);
