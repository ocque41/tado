//! Database query plan cost: sum of `EXPLAIN [ANALYZE]` cost estimates
//! across the project's representative workload queries.
//!
//! This is the query *planner's* cost — a property of the schema +
//! query, not the disk. A schema regression (lost index, accidental
//! seq-scan) shows up identically on SSD and NVMe.
//!
//! Per-stack measurement:
//! - SQLite (rusqlite, sqlite3, better-sqlite3, peewee, etc.):
//!     `EXPLAIN QUERY PLAN <query>` -> sum the row count estimates.
//! - Postgres (sqlx, psycopg, pg, gorm):
//!     `EXPLAIN (FORMAT JSON) <query>` -> sum `Total Cost` from each
//!     plan.
//! - MySQL (mysql2, pymysql, gorm-mysql): `EXPLAIN FORMAT=JSON <q>`.
//!
//! The adapter looks for a `*.sql` corpus under `bench/queries/` or
//! falls back to extracting query strings from the project's source
//! tree via regex. Empty corpus → omit the metric.

use super::{Direction, MetricSample};

pub const NAME: &str = "db_query_cost";
pub const WEIGHT: f64 = 0.10;
pub const DIRECTION: Direction = Direction::LowerIsBetter;
pub const UNIT: &str = "cost";

pub fn sample(value: f64, adapter: &str, notes: Option<String>) -> MetricSample {
    MetricSample {
        value,
        unit: UNIT.to_string(),
        direction: DIRECTION,
        adapter: adapter.to_string(),
        notes,
    }
}
