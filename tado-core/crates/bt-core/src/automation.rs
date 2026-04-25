use crate::error::BtError;
use crate::model::{AutomationOccurrence, AutomationRecord};
use chrono::{DateTime, Duration, Utc};
use chrono_tz::Tz;
use croner::parser::{CronParser, Seconds};
use serde::{Deserialize, Serialize};
use serde_json::Value;

const MAX_EXPANDED_OCCURRENCES: usize = 256;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetryPolicy {
    pub max_attempts: i64,
    pub backoff_seconds: i64,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 1,
            backoff_seconds: 300,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OnceSchedule {
    pub at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CronSchedule {
    pub expr: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntervalSchedule {
    pub every_seconds: i64,
    pub anchor_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct QueueSchedule {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeartbeatSchedule {
    pub stale_after_seconds: i64,
    pub check_every_seconds: Option<i64>,
}

#[derive(Debug, Clone)]
pub enum ScheduleDefinition {
    Once(OnceSchedule),
    Cron(CronSchedule),
    Interval(IntervalSchedule),
    Queue(QueueSchedule),
    Heartbeat(HeartbeatSchedule),
}

pub fn parse_timezone(input: &str) -> Result<Tz, BtError> {
    input
        .parse::<Tz>()
        .map_err(|_| BtError::Validation(format!("invalid timezone: {}", input)))
}

pub fn parse_retry_policy(value: &Value) -> Result<RetryPolicy, BtError> {
    serde_json::from_value(value.clone())
        .map_err(|e| BtError::Validation(format!("invalid retry policy: {}", e)))
        .map(|mut policy: RetryPolicy| {
            if policy.max_attempts < 1 {
                policy.max_attempts = 1;
            }
            if policy.backoff_seconds < 1 {
                policy.backoff_seconds = 1;
            }
            policy
        })
}

pub fn parse_schedule(automation: &AutomationRecord) -> Result<ScheduleDefinition, BtError> {
    match automation.schedule_kind.as_str() {
        "once" => serde_json::from_value::<OnceSchedule>(automation.schedule_json.clone())
            .map(ScheduleDefinition::Once)
            .map_err(|e| BtError::Validation(format!("invalid once schedule: {}", e))),
        "cron" => serde_json::from_value::<CronSchedule>(automation.schedule_json.clone())
            .map(ScheduleDefinition::Cron)
            .map_err(|e| BtError::Validation(format!("invalid cron schedule: {}", e))),
        "interval" | "loop" => {
            serde_json::from_value::<IntervalSchedule>(automation.schedule_json.clone())
                .map(ScheduleDefinition::Interval)
                .map_err(|e| BtError::Validation(format!("invalid interval schedule: {}", e)))
        }
        "queue" | "manual" => Ok(ScheduleDefinition::Queue(QueueSchedule::default())),
        "heartbeat" | "watchdog" => {
            serde_json::from_value::<HeartbeatSchedule>(automation.schedule_json.clone())
                .map(ScheduleDefinition::Heartbeat)
                .map_err(|e| BtError::Validation(format!("invalid heartbeat schedule: {}", e)))
        }
        other => Err(BtError::Validation(format!(
            "unsupported schedule kind: {}",
            other
        ))),
    }
}

pub fn expand_schedule(
    automation: &AutomationRecord,
    now: DateTime<Utc>,
    horizon_end: DateTime<Utc>,
) -> Result<Vec<DateTime<Utc>>, BtError> {
    let schedule = parse_schedule(automation)?;
    let from = automation
        .last_planned_at
        .unwrap_or(automation.created_at - Duration::seconds(1));
    match schedule {
        ScheduleDefinition::Once(def) => expand_once(def, from, horizon_end),
        ScheduleDefinition::Cron(def) => expand_cron(&def, &automation.timezone, from, horizon_end),
        ScheduleDefinition::Interval(def) => expand_interval(&def, automation, from, horizon_end),
        ScheduleDefinition::Queue(_) => Ok(Vec::new()),
        ScheduleDefinition::Heartbeat(def) => {
            if let Some(planned) = heartbeat_due_at(automation, &def, now)? {
                if planned <= horizon_end {
                    return Ok(vec![planned]);
                }
            }
            Ok(Vec::new())
        }
    }
}

fn expand_once(
    schedule: OnceSchedule,
    from: DateTime<Utc>,
    horizon_end: DateTime<Utc>,
) -> Result<Vec<DateTime<Utc>>, BtError> {
    let at = DateTime::parse_from_rfc3339(&schedule.at)
        .map(|d| d.with_timezone(&Utc))
        .map_err(|_| BtError::Validation("once.at must be RFC3339".to_string()))?;
    if at > from && at <= horizon_end {
        Ok(vec![at])
    } else {
        Ok(Vec::new())
    }
}

fn expand_cron(
    schedule: &CronSchedule,
    timezone: &str,
    from: DateTime<Utc>,
    horizon_end: DateTime<Utc>,
) -> Result<Vec<DateTime<Utc>>, BtError> {
    let tz = parse_timezone(timezone)?;
    let parser = CronParser::builder().seconds(Seconds::Optional).build();
    let cron = parser
        .parse(&schedule.expr)
        .map_err(|e| BtError::Validation(format!("invalid cron expr: {}", e)))?;

    let mut cursor = from.with_timezone(&tz);
    let end = horizon_end.with_timezone(&tz);
    let mut out = Vec::new();

    while out.len() < MAX_EXPANDED_OCCURRENCES {
        let next = cron.find_next_occurrence(&cursor, false).map_err(|e| {
            BtError::Validation(format!("unable to find next cron occurrence: {}", e))
        })?;
        let next_utc = next.with_timezone(&Utc);
        if next_utc > horizon_end || next > end {
            break;
        }
        out.push(next_utc);
        cursor = next;
    }

    Ok(out)
}

fn expand_interval(
    schedule: &IntervalSchedule,
    automation: &AutomationRecord,
    from: DateTime<Utc>,
    horizon_end: DateTime<Utc>,
) -> Result<Vec<DateTime<Utc>>, BtError> {
    if schedule.every_seconds < 1 {
        return Err(BtError::Validation(
            "interval.every_seconds must be >= 1".to_string(),
        ));
    }

    let mut next = if let Some(anchor_at) = &schedule.anchor_at {
        DateTime::parse_from_rfc3339(anchor_at)
            .map(|d| d.with_timezone(&Utc))
            .map_err(|_| BtError::Validation("interval.anchor_at must be RFC3339".to_string()))?
    } else {
        automation.created_at
    };
    let step = Duration::seconds(schedule.every_seconds);
    while next <= from {
        next += step;
    }

    let mut out = Vec::new();
    while next <= horizon_end && out.len() < MAX_EXPANDED_OCCURRENCES {
        out.push(next);
        next += step;
    }
    Ok(out)
}

pub fn heartbeat_due_at(
    automation: &AutomationRecord,
    schedule: &HeartbeatSchedule,
    now: DateTime<Utc>,
) -> Result<Option<DateTime<Utc>>, BtError> {
    if schedule.stale_after_seconds < 1 {
        return Err(BtError::Validation(
            "heartbeat.stale_after_seconds must be >= 1".to_string(),
        ));
    }
    let last_planned = automation.last_planned_at.unwrap_or(automation.created_at);
    let stale_at = last_planned + Duration::seconds(schedule.stale_after_seconds);
    if stale_at <= now {
        Ok(Some(stale_at))
    } else {
        Ok(None)
    }
}

pub fn next_retry_at(
    occurrence: &AutomationOccurrence,
    retry_policy: &RetryPolicy,
) -> DateTime<Utc> {
    let base = occurrence
        .finished_at
        .or(occurrence.started_at)
        .or(occurrence.leased_at)
        .unwrap_or_else(Utc::now);
    base + Duration::seconds(retry_policy.backoff_seconds)
}

pub fn render_prompt(
    template: &str,
    automation: &AutomationRecord,
    occurrence: &AutomationOccurrence,
    shared_context: Option<&Value>,
) -> String {
    let mut rendered = template
        .replace("{{automation.title}}", &automation.title)
        .replace("{{automation.id}}", &automation.id)
        .replace("{{occurrence.id}}", &occurrence.id)
        .replace("{{planned_at}}", &occurrence.planned_at.to_rfc3339());

    if let Some(doc_id) = &automation.doc_id {
        rendered = rendered.replace("{{doc_id}}", doc_id);
    }
    if let Some(task_id) = &automation.task_id {
        rendered = rendered.replace("{{task_id}}", task_id);
    }
    let shared_context_text = shared_context
        .map(|value| value.to_string())
        .unwrap_or_else(|| "{}".to_string());
    rendered.replace("{{shared_context}}", &shared_context_text)
}

pub fn completion_class(
    succeeded: bool,
    intervention_count: i64,
    lateness_seconds: i64,
) -> (&'static str, f64) {
    if !succeeded {
        return ("failed", 0.0);
    }
    if intervention_count == 0 && lateness_seconds <= 60 {
        return ("excellent", 1.0);
    }
    if intervention_count <= 1 && lateness_seconds <= 900 {
        return ("good", 0.8);
    }
    if intervention_count <= 2 && lateness_seconds <= 3600 {
        return ("needs_review", 0.55);
    }
    ("intervention_heavy", 0.35)
}
