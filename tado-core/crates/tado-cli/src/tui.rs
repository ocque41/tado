#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkKind {
    Tile,
    Todo,
    Eternal,
    Dispatch,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkRow {
    pub id: String,
    pub kind: WorkKind,
    pub title: String,
    pub status: String,
    pub project: Option<String>,
    pub target: Option<String>,
    pub promptable: bool,
    pub created_at: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SendTarget {
    Tile { target: String },
    Eternal { run_id: String },
    Dispatch { run_id: String },
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TuiState {
    pub rows: Vec<WorkRow>,
    pub selected: usize,
    pub draft: String,
    pub status: Option<String>,
    pub connection_error: Option<String>,
}

impl TuiState {
    pub fn set_rows(&mut self, rows: Vec<WorkRow>) {
        self.rows = sort_rows(rows);
        if self.rows.is_empty() {
            self.selected = 0;
        } else if self.selected >= self.rows.len() {
            self.selected = self.rows.len() - 1;
        }
    }

    pub fn move_selection(&mut self, delta: isize) {
        if self.rows.is_empty() {
            self.selected = 0;
            return;
        }
        let current = self.selected as isize;
        let max = self.rows.len() as isize - 1;
        self.selected = (current + delta).clamp(0, max) as usize;
    }

    pub fn selected(&self) -> Option<&WorkRow> {
        self.rows.get(self.selected)
    }

    pub fn send_target(&self) -> Option<SendTarget> {
        let row = self.selected()?;
        if !row.promptable {
            return None;
        }
        let target = row.target.clone()?;
        match row.kind {
            WorkKind::Tile => Some(SendTarget::Tile { target }),
            WorkKind::Eternal => Some(SendTarget::Eternal { run_id: target }),
            WorkKind::Dispatch => Some(SendTarget::Dispatch { run_id: target }),
            WorkKind::Todo => None,
        }
    }
}

pub fn sort_rows(mut rows: Vec<WorkRow>) -> Vec<WorkRow> {
    rows.sort_by(|a, b| {
        priority(a)
            .cmp(&priority(b))
            .then_with(|| b.created_at.cmp(&a.created_at))
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    rows
}

pub fn priority(row: &WorkRow) -> u8 {
    let status = row.status.replace([' ', '_'], "").to_ascii_lowercase();
    if matches!(
        status.as_str(),
        "needsinput" | "awaitingresponse" | "awaitingreview"
    ) {
        return 0;
    }
    if matches!(status.as_str(), "running" | "dispatching") {
        return 1;
    }
    if matches!(
        status.as_str(),
        "planning" | "queued" | "pending" | "drafted" | "ready"
    ) {
        return 2;
    }
    3
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, kind: WorkKind, status: &str, created_at: i64, promptable: bool) -> WorkRow {
        WorkRow {
            id: id.to_string(),
            kind,
            title: id.to_string(),
            status: status.to_string(),
            project: None,
            target: Some(id.to_string()),
            promptable,
            created_at,
        }
    }

    #[test]
    fn sorts_needs_input_before_running_then_queued() {
        let rows = sort_rows(vec![
            row("queued", WorkKind::Todo, "pending", 30, false),
            row("run", WorkKind::Tile, "running", 20, true),
            row("needs", WorkKind::Tile, "needsInput", 10, true),
        ]);
        let ids: Vec<_> = rows.into_iter().map(|r| r.id).collect();
        assert_eq!(ids, vec!["needs", "run", "queued"]);
    }

    #[test]
    fn clamps_selection_when_rows_shrink() {
        let mut state = TuiState::default();
        state.set_rows(vec![
            row("a", WorkKind::Tile, "running", 1, true),
            row("b", WorkKind::Tile, "running", 2, true),
        ]);
        state.move_selection(10);
        assert_eq!(state.selected, 1);
        state.set_rows(vec![row("a", WorkKind::Tile, "running", 1, true)]);
        assert_eq!(state.selected, 0);
    }

    #[test]
    fn resolves_send_target_for_dispatch_but_not_plain_todo() {
        let mut state = TuiState::default();
        state.set_rows(vec![row("d1", WorkKind::Dispatch, "dispatching", 1, true)]);
        assert_eq!(
            state.send_target(),
            Some(SendTarget::Dispatch {
                run_id: "d1".to_string()
            })
        );

        state.set_rows(vec![row("todo", WorkKind::Todo, "pending", 1, false)]);
        assert_eq!(state.send_target(), None);
    }
}
