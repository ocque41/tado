//! IO syscall count per logical operation: `read`, `write`, `open`,
//! `close`, `lseek`, `mmap` calls per benchmark iteration.
//!
//! A *count*. Captures "we accidentally added 3 extra `fopen`s to the
//! inner loop" the same way on any disk, any filesystem.
//!
//! Per-stack measurement (macOS / Linux):
//! - All stacks: `dtrace -n 'syscall::*:entry /pid == $target/ { @[probefunc] = count(); }'`
//! - Linux fallback: `strace -c -p $pid`
//!
//! On macOS the bench process needs to run with the System Integrity
//! Protection's dtrace allowance — that's a one-time user setup. The
//! adapter falls back to `value: 0.0, notes: Some("syscall counting
//! unavailable")` if dtrace fails, which the scoring layer treats as a
//! neutral 1.0.

use super::{Direction, MetricSample};

pub const NAME: &str = "io_syscalls_per_op";
pub const WEIGHT: f64 = 0.10;
pub const DIRECTION: Direction = Direction::LowerIsBetter;
pub const UNIT: &str = "syscalls/op";

pub fn sample(value: f64, adapter: &str, notes: Option<String>) -> MetricSample {
    MetricSample {
        value,
        unit: UNIT.to_string(),
        direction: DIRECTION,
        adapter: adapter.to_string(),
        notes,
    }
}
