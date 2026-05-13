use std::{
    collections::HashSet,
    io,
    time::{Duration, Instant},
};

use anyhow::Result;
use chrono::DateTime;
use crossterm::{
    event::{self, Event, KeyCode, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap},
    Frame, Terminal,
};
use serde_json::{json, Value};
use tado_cli::{
    call,
    tui::{SendTarget, TuiState, WorkKind, WorkRow},
    ControlClientError,
};

fn main() -> Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let result = run(&mut terminal);

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    result
}

fn run(terminal: &mut Terminal<CrosstermBackend<io::Stdout>>) -> Result<()> {
    let mut state = TuiState::default();
    let mut last_refresh = Instant::now() - Duration::from_secs(10);

    loop {
        if last_refresh.elapsed() >= Duration::from_secs(2) {
            refresh(&mut state);
            last_refresh = Instant::now();
        }

        terminal.draw(|frame| draw(frame, &state))?;

        if event::poll(Duration::from_millis(120))? {
            if let Event::Key(key) = event::read()? {
                match key.code {
                    KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => break,
                    KeyCode::Char('q') if state.draft.is_empty() => break,
                    KeyCode::Up => state.move_selection(-1),
                    KeyCode::Down => state.move_selection(1),
                    KeyCode::Esc => {
                        state.draft.clear();
                        state.status = None;
                    }
                    KeyCode::Backspace => {
                        state.draft.pop();
                    }
                    KeyCode::Enter => {
                        send_current(&mut state);
                        last_refresh = Instant::now() - Duration::from_secs(10);
                    }
                    KeyCode::Char(ch)
                        if !key.modifiers.contains(KeyModifiers::CONTROL)
                            && !key.modifiers.contains(KeyModifiers::SUPER) =>
                    {
                        state.draft.push(ch);
                    }
                    _ => {}
                }
            }
        }
    }

    Ok(())
}

fn draw(frame: &mut Frame<'_>, state: &TuiState) {
    let area = frame.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(3),
            Constraint::Length(1),
        ])
        .split(area);

    let title = Paragraph::new(Line::from(vec![
        Span::styled(
            "Tado TUI",
            Style::default()
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(
            "↑↓ select  Enter send  Esc clear  q quit",
            Style::default().fg(Color::DarkGray),
        ),
    ]))
    .block(Block::default().borders(Borders::BOTTOM));
    frame.render_widget(title, chunks[0]);

    if let Some(message) = &state.connection_error {
        let paragraph = Paragraph::new(message.as_str())
            .style(Style::default().fg(Color::Yellow))
            .block(
                Block::default()
                    .title("Tado connection")
                    .borders(Borders::ALL),
            )
            .wrap(Wrap { trim: true });
        frame.render_widget(paragraph, chunks[1]);
    } else {
        let body = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(58), Constraint::Percentage(42)])
            .split(chunks[1]);
        draw_list(frame, state, body[0]);
        draw_inspector(frame, state, body[1]);
    }

    let input = Paragraph::new(state.draft.as_str())
        .style(Style::default().fg(Color::White))
        .block(Block::default().title("Prompt").borders(Borders::ALL));
    frame.render_widget(input, chunks[2]);

    let status = state.status.as_deref().unwrap_or("");
    frame.render_widget(
        Paragraph::new(status).style(Style::default().fg(Color::DarkGray)),
        chunks[3],
    );
}

fn draw_list(frame: &mut Frame<'_>, state: &TuiState, area: ratatui::layout::Rect) {
    let items: Vec<ListItem> = if state.rows.is_empty() {
        vec![ListItem::new(
            "No active work. Create a todo or start a run in Tado.",
        )]
    } else {
        state
            .rows
            .iter()
            .map(|row| {
                let project = row.project.as_deref().unwrap_or("no project");
                ListItem::new(Line::from(vec![
                    Span::styled(kind_label(&row.kind), Style::default().fg(Color::Cyan)),
                    Span::raw(" "),
                    Span::styled(row.title.as_str(), Style::default().fg(Color::White)),
                    Span::raw("  "),
                    Span::styled(row.status.as_str(), Style::default().fg(Color::Yellow)),
                    Span::raw("  "),
                    Span::styled(project, Style::default().fg(Color::DarkGray)),
                ]))
            })
            .collect()
    };

    let mut list_state = ListState::default();
    if !state.rows.is_empty() {
        list_state.select(Some(state.selected));
    }
    let list = List::new(items)
        .block(Block::default().title("Active work").borders(Borders::ALL))
        .highlight_style(
            Style::default()
                .bg(Color::DarkGray)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("> ");
    frame.render_stateful_widget(list, area, &mut list_state);
}

fn draw_inspector(frame: &mut Frame<'_>, state: &TuiState, area: ratatui::layout::Rect) {
    let text = if let Some(row) = state.selected() {
        let target = row.target.as_deref().unwrap_or("none");
        let project = row.project.as_deref().unwrap_or("No project");
        let send = if row.promptable {
            "Enter sends your prompt to this item."
        } else {
            "This todo has no live session. Spawn it in Tado before sending follow-ups."
        };
        format!(
            "{}\n\nType: {}\nStatus: {}\nProject: {}\nTarget: {}\n\n{}",
            row.title,
            kind_label(&row.kind),
            row.status,
            project,
            target,
            send
        )
    } else {
        "Select a row.".to_string()
    };
    let paragraph = Paragraph::new(text)
        .block(Block::default().title("Inspector").borders(Borders::ALL))
        .wrap(Wrap { trim: true });
    frame.render_widget(paragraph, area);
}

fn refresh(state: &mut TuiState) {
    match fetch_rows() {
        Ok(rows) => {
            state.connection_error = None;
            state.set_rows(rows);
        }
        Err(ControlClientError::AppNotRunning(_)) => {
            state.connection_error = Some(
                "Tado is not running. Open the Tado macOS app, then run tado-tui again."
                    .to_string(),
            );
            state.set_rows(Vec::new());
        }
        Err(err) => {
            state.connection_error = Some(format!("{err}"));
            state.set_rows(Vec::new());
        }
    }
}

fn fetch_rows() -> Result<Vec<WorkRow>, ControlClientError> {
    let mut rows = Vec::new();
    let mut live_todos = HashSet::new();

    if let Some(data) = call("tado_use.list_tiles", json!({}))?.data {
        if let Some(tiles) = data.get("tiles").and_then(Value::as_array) {
            for tile in tiles {
                let todo_id = str_field(tile, "todo_id").unwrap_or_default().to_string();
                if !todo_id.is_empty() {
                    live_todos.insert(todo_id.clone());
                }
                rows.push(WorkRow {
                    id: format!("tile:{todo_id}"),
                    kind: WorkKind::Tile,
                    title: str_field(tile, "todo_text")
                        .or_else(|| str_field(tile, "title"))
                        .unwrap_or("Untitled tile")
                        .to_string(),
                    status: str_field(tile, "status").unwrap_or("running").to_string(),
                    project: non_empty(str_field(tile, "project")),
                    target: Some(todo_id),
                    promptable: true,
                    created_at: parse_timestamp(str_field(tile, "started_at")),
                });
            }
        }
    }

    if let Some(data) = call("tado_use.todo_list", json!({ "state": "active" }))?.data {
        if let Some(todos) = data.get("todos").and_then(Value::as_array) {
            for todo in todos {
                let todo_id = str_field(todo, "todo_id").unwrap_or_default().to_string();
                if live_todos.contains(&todo_id) {
                    continue;
                }
                rows.push(WorkRow {
                    id: format!("todo:{todo_id}"),
                    kind: WorkKind::Todo,
                    title: str_field(todo, "text")
                        .unwrap_or("Untitled todo")
                        .to_string(),
                    status: str_field(todo, "status").unwrap_or("pending").to_string(),
                    project: non_empty(str_field(todo, "project_name")),
                    target: Some(todo_id),
                    promptable: false,
                    created_at: parse_timestamp(str_field(todo, "created_at")),
                });
            }
        }
    }

    if let Some(data) = call("tado_use.eternal_list", json!({}))?.data {
        if let Some(runs) = data.get("runs").and_then(Value::as_array) {
            for run in runs {
                let run_id = str_field(run, "run_id").unwrap_or_default().to_string();
                rows.push(WorkRow {
                    id: format!("eternal:{run_id}"),
                    kind: WorkKind::Eternal,
                    title: str_field(run, "label").unwrap_or("Eternal run").to_string(),
                    status: str_field(run, "state").unwrap_or("drafted").to_string(),
                    project: non_empty(str_field(run, "project_name")),
                    target: Some(run_id),
                    promptable: true,
                    created_at: parse_timestamp(str_field(run, "created_at")),
                });
            }
        }
    }

    if let Some(data) = call("tado_use.dispatch_list", json!({}))?.data {
        if let Some(runs) = data.get("runs").and_then(Value::as_array) {
            for run in runs {
                let run_id = str_field(run, "run_id").unwrap_or_default().to_string();
                rows.push(WorkRow {
                    id: format!("dispatch:{run_id}"),
                    kind: WorkKind::Dispatch,
                    title: str_field(run, "label")
                        .unwrap_or("Dispatch run")
                        .to_string(),
                    status: str_field(run, "state").unwrap_or("drafted").to_string(),
                    project: non_empty(str_field(run, "project_name")),
                    target: Some(run_id),
                    promptable: true,
                    created_at: parse_timestamp(str_field(run, "created_at")),
                });
            }
        }
    }

    Ok(rows)
}

fn send_current(state: &mut TuiState) {
    let message = state.draft.trim().to_string();
    if message.is_empty() {
        return;
    }

    let result = match state.send_target() {
        Some(SendTarget::Tile { target }) => call(
            "tado_use.tile_send",
            json!({ "target": target, "message": message }),
        ),
        Some(SendTarget::Eternal { run_id }) => call(
            "tado_use.eternal_intervene",
            json!({ "run_id": run_id, "directive": message }),
        ),
        Some(SendTarget::Dispatch { run_id }) => call(
            "tado_use.dispatch_intervene",
            json!({ "run_id": run_id, "directive": message }),
        ),
        None => {
            state.status = Some("Selected row is not a follow-up target.".to_string());
            return;
        }
    };

    match result {
        Ok(_) => {
            state.draft.clear();
            state.status = Some("Sent.".to_string());
        }
        Err(ControlClientError::AppNotRunning(_)) => {
            state.connection_error = Some(
                "Tado is not running. Open the Tado macOS app, then run tado-tui again."
                    .to_string(),
            );
        }
        Err(err) => {
            state.status = Some(format!("{err}"));
        }
    }
}

fn str_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn non_empty(value: Option<&str>) -> Option<String> {
    value.and_then(|s| {
        let trimmed = s.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    })
}

fn parse_timestamp(value: Option<&str>) -> i64 {
    value
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|dt| dt.timestamp())
        .unwrap_or_default()
}

fn kind_label(kind: &WorkKind) -> &'static str {
    match kind {
        WorkKind::Tile => "tile",
        WorkKind::Todo => "todo",
        WorkKind::Eternal => "eternal",
        WorkKind::Dispatch => "dispatch",
    }
}
