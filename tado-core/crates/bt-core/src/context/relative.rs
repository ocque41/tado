//! Deterministic relative-time formatter for the spawn-time preamble.
//!
//! The Swift composer used `RelativeDateTimeFormatter.localizedString`,
//! which produces locale-specific text (`"5 min. ago"` / `"hace 5
//! min."`). That can't be byte-replicated from Rust without
//! depending on Apple's CFLocale. Phase 4 standardises on the same
//! deterministic shape on both sides:
//!
//! ```text
//!   <60 s         → "just now"
//!   <60 m         → "{n}m ago"
//!   <24 h         → "{n}h ago"
//!   <7 d          → "{n}d ago"
//!   <30 d         → "{n}w ago"   (weeks, integer)
//!   <365 d        → "{n}mo ago"  (months ≈ 30 days)
//!   else          → "{n}y ago"
//!   future        → "in {x}"     (mirror)
//! ```
//!
//! Phase 4's Swift change updates `DomeContextPreamble` to call a
//! Swift mirror of this exact algorithm so cross-language outputs are
//! identical down to the byte.

use chrono::{DateTime, Utc};

pub fn format_relative_ago(ts: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let secs = (now - ts).num_seconds();
    let abs = secs.abs();
    let body = bucket(abs);
    if secs >= 0 {
        if body == "just now" {
            "just now".to_string()
        } else {
            format!("{body} ago")
        }
    } else if body == "just now" {
        "in a moment".to_string()
    } else {
        format!("in {body}")
    }
}

fn bucket(abs_secs: i64) -> String {
    if abs_secs < 60 {
        "just now".to_string()
    } else if abs_secs < 3_600 {
        format!("{}m", abs_secs / 60)
    } else if abs_secs < 86_400 {
        format!("{}h", abs_secs / 3_600)
    } else if abs_secs < 604_800 {
        format!("{}d", abs_secs / 86_400)
    } else if abs_secs < 2_592_000 {
        format!("{}w", abs_secs / 604_800)
    } else if abs_secs < 31_536_000 {
        format!("{}mo", abs_secs / 2_592_000)
    } else {
        format!("{}y", abs_secs / 31_536_000)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-04-27T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn just_now_under_60s() {
        let n = now();
        assert_eq!(format_relative_ago(n - Duration::seconds(5), n), "just now");
        assert_eq!(format_relative_ago(n - Duration::seconds(59), n), "just now");
    }

    #[test]
    fn minutes_under_an_hour() {
        let n = now();
        assert_eq!(format_relative_ago(n - Duration::seconds(60), n), "1m ago");
        assert_eq!(format_relative_ago(n - Duration::minutes(45), n), "45m ago");
    }

    #[test]
    fn hours_then_days_then_weeks_then_months_then_years() {
        let n = now();
        assert_eq!(format_relative_ago(n - Duration::hours(3), n), "3h ago");
        assert_eq!(format_relative_ago(n - Duration::days(5), n), "5d ago");
        assert_eq!(format_relative_ago(n - Duration::days(10), n), "1w ago");
        assert_eq!(format_relative_ago(n - Duration::days(45), n), "1mo ago");
        assert_eq!(format_relative_ago(n - Duration::days(400), n), "1y ago");
    }

    #[test]
    fn future_timestamps_render_with_in_prefix() {
        let n = now();
        assert_eq!(format_relative_ago(n + Duration::minutes(15), n), "in 15m");
        assert_eq!(format_relative_ago(n + Duration::seconds(5), n), "in a moment");
    }
}
