use std::{
    io,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::Result;
use chrono::DateTime;
use clap::Parser;
use crossterm::{
    event::{self, Event, KeyCode, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap},
    Frame, Terminal,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tado_cli::tui::{SendTarget, TuiState, WorkKind, WorkRow};
use tado_runtime::{ensure_daemon, profile_from_env, RuntimeClient};

#[derive(Parser, Debug)]
#[command(name = "tado-tui")]
#[command(about = "Agent OS terminal UI backed by the Tado runtime daemon.")]
struct Cli {
    #[arg(long)]
    profile: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    Work,
    Board,
    Mux,
    Events,
    Use,
    Projects,
    Settings,
}

impl Mode {
    fn all() -> &'static [(Mode, &'static str)] {
        &[
            (Mode::Work, "Work"),
            (Mode::Board, "Board"),
            (Mode::Mux, "Mux"),
            (Mode::Events, "Events"),
            (Mode::Use, "Use"),
            (Mode::Projects, "Projects"),
            (Mode::Settings, "Settings"),
        ]
    }

    fn next(self) -> Self {
        let modes = Self::all();
        let index = modes
            .iter()
            .position(|(mode, _)| *mode == self)
            .unwrap_or(0);
        modes[(index + 1) % modes.len()].0
    }

    fn previous(self) -> Self {
        let modes = Self::all();
        let index = modes
            .iter()
            .position(|(mode, _)| *mode == self)
            .unwrap_or(0);
        modes[(index + modes.len() - 1) % modes.len()].0
    }
}

struct AgentOsState {
    profile: String,
    client: RuntimeClient,
    tui: TuiState,
    mode: Mode,
    screen_text: String,
    events_text: String,
    board_columns: Vec<KanbanColumn>,
    projects: Vec<ProjectView>,
    project_selected: usize,
    active_project_root: Option<String>,
    runtime_text: String,
    settings: UiSettings,
    settings_selected: usize,
    scroll: u16,
    follow_output: bool,
    last_target: Option<String>,
    suggestion_selected: usize,
    power_armed_until: Option<Instant>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct KanbanColumn {
    key: String,
    title: String,
    cards: Vec<KanbanCard>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct KanbanCard {
    session_id: String,
    title: String,
    status: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ProjectView {
    id: String,
    name: String,
    root: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
struct UiSettings {
    default_engine: usize,
    codex_mode: usize,
    codex_model: usize,
    codex_effort: usize,
    codex_alternate_screen: bool,
    codex_account_label: String,
    advisor_enabled: bool,
    advisor_defaults_initialized: bool,
    advisor_executioner_engine: usize,
    advisor_executioner_codex_mode: usize,
    advisor_executioner_codex_model: usize,
    advisor_executioner_codex_effort: usize,
    advisor_advisor_engine: usize,
    advisor_advisor_codex_mode: usize,
    advisor_advisor_codex_model: usize,
    advisor_advisor_codex_effort: usize,
    random_tile_color: bool,
    default_theme: usize,
    terminal_font_size: u8,
    cursor_blink: bool,
    bell_mode: usize,
    grid_columns: u8,
    code_indexing_enabled: bool,
    auto_activate_project: bool,
    follow_transcript: bool,
    compact_board: bool,
    show_done_cards: bool,
    human_events: bool,
}

impl Default for UiSettings {
    fn default() -> Self {
        Self {
            default_engine: 1,
            codex_mode: 0,
            codex_model: 0,
            codex_effort: 0,
            codex_alternate_screen: false,
            codex_account_label: "default".to_string(),
            advisor_enabled: false,
            advisor_defaults_initialized: false,
            advisor_executioner_engine: 0,
            advisor_executioner_codex_mode: 0,
            advisor_executioner_codex_model: 1,
            advisor_executioner_codex_effort: 0,
            advisor_advisor_engine: 0,
            advisor_advisor_codex_mode: 0,
            advisor_advisor_codex_model: 0,
            advisor_advisor_codex_effort: 3,
            random_tile_color: false,
            default_theme: 0,
            terminal_font_size: 13,
            cursor_blink: true,
            bell_mode: 1,
            grid_columns: 3,
            code_indexing_enabled: true,
            auto_activate_project: true,
            follow_transcript: true,
            compact_board: false,
            show_done_cards: true,
            human_events: true,
        }
    }
}

const DEFAULT_ENGINES: &[&str] = &["shell", "codex"];
const ENGINE_LABELS: &[&str] = &["Shell", "Codex"];
const CODEX_MODES: &[(&str, &[&str])] = &[
    ("Default permissions", &[]),
    (
        "Full access",
        &[
            "--ask-for-approval",
            "never",
            "--sandbox",
            "danger-full-access",
        ],
    ),
    ("Custom config", &[]),
];
const CODEX_MODELS: &[(&str, &str)] = &[
    ("GPT-5.5", "gpt-5.5"),
    ("GPT-5.4", "gpt-5.4"),
    ("GPT-5.4-Mini", "gpt-5.4-mini"),
    ("GPT-5.3-Codex", "gpt-5.3-codex"),
    ("GPT-5.2", "gpt-5.2"),
];
const CODEX_EFFORTS: &[(&str, Option<&str>)] = &[
    ("Auto", None),
    ("Low", Some("low")),
    ("Medium", Some("medium")),
    ("High", Some("high")),
    ("Extra high", Some("xhigh")),
];
const THEMES: &[&str] = &[
    "Ember",
    "Tado Dark",
    "Copper",
    "Mac Pro",
    "Solarized Dark",
    "Dracula",
    "Nord",
    "Monokai",
    "Tokyo Night",
    "Gruvbox",
];
const BELL_MODES: &[&str] = &["Off", "Audible", "Visual", "Audible + visual"];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AdvisorRole {
    Executioner,
    Advisor,
}

#[derive(Clone, Copy)]
struct CommandSpec {
    verb: &'static str,
    args: &'static str,
    summary: &'static str,
}

const COMMANDS: &[CommandSpec] = &[
    CommandSpec {
        verb: "/spawn",
        args: "<shell command>",
        summary: "spawn a shell PTY",
    },
    CommandSpec {
        verb: "/codex",
        args: "<prompt>",
        summary: "spawn Codex",
    },
    CommandSpec {
        verb: "/bootstrap",
        args: "<action> [engine]",
        summary: "request project bootstrap",
    },
    CommandSpec {
        verb: "/dispatch",
        args: "start|list|status|crafted|accept|reject",
        summary: "manage Dispatch runs",
    },
    CommandSpec {
        verb: "/project",
        args: "status|add|create|use|list",
        summary: "manage profile projects",
    },
    CommandSpec {
        verb: "/projects",
        args: "status|add|create|use|list",
        summary: "manage profile projects",
    },
    CommandSpec {
        verb: "/move",
        args: "[session] <lane>",
        summary: "move a Kanban card",
    },
    CommandSpec {
        verb: "/lane",
        args: "<key> <title>",
        summary: "add a Kanban lane",
    },
    CommandSpec {
        verb: "/broadcast",
        args: "<message>",
        summary: "send to live sessions",
    },
    CommandSpec {
        verb: "/notify",
        args: "<title>",
        summary: "write an event",
    },
    CommandSpec {
        verb: "/stop",
        args: "[session]",
        summary: "soft stop",
    },
    CommandSpec {
        verb: "/hard-kill",
        args: "[session]",
        summary: "hard kill with power mode",
    },
    CommandSpec {
        verb: "/delete",
        args: "[session]",
        summary: "kill and remove a session",
    },
    CommandSpec {
        verb: "/search",
        args: "<text>",
        summary: "search transcripts",
    },
    CommandSpec {
        verb: "/power",
        args: "tado-power",
        summary: "arm destructive actions",
    },
    CommandSpec {
        verb: "/shutdown",
        args: "",
        summary: "stop daemon with power mode",
    },
    CommandSpec {
        verb: "/help",
        args: "",
        summary: "show commands",
    },
];

fn main() -> Result<()> {
    let cli = Cli::parse();
    let profile = profile_from_env(cli.profile);
    let client = ensure_daemon(&profile)?;

    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let result = run(&mut terminal, profile, client);

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    result
}

fn run(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    profile: String,
    client: RuntimeClient,
) -> Result<()> {
    let mut state = AgentOsState {
        profile,
        client,
        tui: TuiState::default(),
        mode: Mode::Work,
        screen_text: String::new(),
        events_text: String::new(),
        board_columns: Vec::new(),
        projects: Vec::new(),
        project_selected: 0,
        active_project_root: None,
        runtime_text: String::new(),
        settings: UiSettings::default(),
        settings_selected: 0,
        scroll: 0,
        follow_output: true,
        last_target: None,
        suggestion_selected: 0,
        power_armed_until: None,
    };
    load_settings(&mut state);
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
                    KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        scroll_by(&mut state, -10);
                    }
                    KeyCode::Char('d') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        scroll_by(&mut state, 10);
                    }
                    KeyCode::Char('q') if state.tui.draft.is_empty() => break,
                    KeyCode::Char('X') if state.tui.draft.is_empty() => {
                        let status =
                            delete_selected_work(&mut state).unwrap_or_else(|err| err.to_string());
                        state.tui.status = Some(status);
                        last_refresh = Instant::now() - Duration::from_secs(10);
                    }
                    _ if shifted_page_mode(key.code, key.modifiers).is_some() => {
                        set_mode(
                            &mut state,
                            shifted_page_mode(key.code, key.modifiers).unwrap(),
                        );
                    }
                    KeyCode::Tab => {
                        if command_palette_visible(&state) {
                            move_suggestion(&mut state, 1);
                        } else {
                            let next = state.mode.next();
                            set_mode(&mut state, next);
                        }
                    }
                    KeyCode::BackTab => {
                        if command_palette_visible(&state) {
                            move_suggestion(&mut state, -1);
                        } else {
                            let previous = state.mode.previous();
                            set_mode(&mut state, previous);
                        }
                    }
                    KeyCode::Char(' ') if state.tui.draft.is_empty() => match state.mode {
                        Mode::Projects => {
                            let status = activate_selected_project(&mut state)
                                .unwrap_or_else(|err| err.to_string());
                            state.tui.status = Some(status);
                            last_refresh = Instant::now() - Duration::from_secs(10);
                        }
                        Mode::Settings => {
                            adjust_setting(&mut state, 1);
                            last_refresh = Instant::now() - Duration::from_secs(10);
                        }
                        _ => {}
                    },
                    KeyCode::PageUp => scroll_by(&mut state, -20),
                    KeyCode::PageDown => scroll_by(&mut state, 20),
                    KeyCode::Home => {
                        state.scroll = 0;
                        state.follow_output = false;
                    }
                    KeyCode::End => {
                        state.follow_output = true;
                        state.settings.follow_transcript = true;
                        state.scroll = u16::MAX;
                    }
                    KeyCode::Up if command_palette_visible(&state) => {
                        move_suggestion(&mut state, -1);
                    }
                    KeyCode::Down if command_palette_visible(&state) => {
                        move_suggestion(&mut state, 1);
                    }
                    KeyCode::Up if state.tui.draft.is_empty() && state.mode == Mode::Projects => {
                        move_project_selection(&mut state, -1);
                    }
                    KeyCode::Down if state.tui.draft.is_empty() && state.mode == Mode::Projects => {
                        move_project_selection(&mut state, 1);
                    }
                    KeyCode::Up if state.tui.draft.is_empty() && state.mode == Mode::Settings => {
                        move_setting_selection(&mut state, -1);
                    }
                    KeyCode::Down if state.tui.draft.is_empty() && state.mode == Mode::Settings => {
                        move_setting_selection(&mut state, 1);
                    }
                    KeyCode::Left if state.tui.draft.is_empty() && state.mode == Mode::Settings => {
                        adjust_setting(&mut state, -1);
                        last_refresh = Instant::now() - Duration::from_secs(10);
                    }
                    KeyCode::Right
                        if state.tui.draft.is_empty() && state.mode == Mode::Settings =>
                    {
                        adjust_setting(&mut state, 1);
                        last_refresh = Instant::now() - Duration::from_secs(10);
                    }
                    KeyCode::Up => {
                        state.tui.move_selection(-1);
                        state.follow_output = true;
                    }
                    KeyCode::Down => {
                        state.tui.move_selection(1);
                        state.follow_output = true;
                    }
                    KeyCode::Esc => {
                        state.tui.draft.clear();
                        state.tui.status = None;
                        state.suggestion_selected = 0;
                    }
                    KeyCode::Backspace => {
                        state.tui.draft.pop();
                        clamp_suggestion(&mut state);
                    }
                    KeyCode::Enter => {
                        if !complete_command(&mut state) {
                            submit(&mut state);
                            last_refresh = Instant::now() - Duration::from_secs(10);
                        }
                    }
                    KeyCode::Char(ch)
                        if !key.modifiers.contains(KeyModifiers::CONTROL)
                            && !key.modifiers.contains(KeyModifiers::SUPER) =>
                    {
                        state.tui.draft.push(ch);
                        clamp_suggestion(&mut state);
                    }
                    _ => {}
                }
            }
        }
    }

    Ok(())
}

fn draw(frame: &mut Frame<'_>, state: &AgentOsState) {
    let area = frame.area();
    let prompt_height = if command_palette_visible(state) { 8 } else { 3 };
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(4),
            Constraint::Min(8),
            Constraint::Length(prompt_height),
            Constraint::Length(1),
        ])
        .split(area);

    draw_header(frame, state, chunks[0]);

    if let Some(message) = &state.tui.connection_error {
        let paragraph = Paragraph::new(message.as_str())
            .style(Style::default().fg(Color::Yellow))
            .block(Block::default().title("Runtime").borders(Borders::ALL))
            .wrap(Wrap { trim: true });
        frame.render_widget(paragraph, chunks[1]);
    } else {
        match state.mode {
            Mode::Work => draw_work(frame, state, chunks[1]),
            Mode::Board => draw_board(frame, state, chunks[1]),
            Mode::Mux => draw_mux(frame, state, chunks[1]),
            Mode::Events => draw_text(
                frame,
                "Timeline",
                &state.events_text,
                chunks[1],
                state.scroll,
            ),
            Mode::Use => draw_text(frame, "Operator", use_text(), chunks[1], state.scroll),
            Mode::Projects => draw_projects(frame, state, chunks[1]),
            Mode::Settings => draw_settings(frame, state, chunks[1]),
        }
    }

    let prompt_title = if is_power_armed(state) {
        "Prompt  power armed"
    } else {
        "Prompt"
    };
    let input = Paragraph::new(prompt_lines(state))
        .style(Style::default().fg(Color::White))
        .block(Block::default().title(prompt_title).borders(Borders::ALL));
    frame.render_widget(input, chunks[2]);

    let status = state.tui.status.as_deref().unwrap_or("");
    frame.render_widget(
        Paragraph::new(status).style(Style::default().fg(Color::DarkGray)),
        chunks[3],
    );
}

fn draw_header(frame: &mut Frame<'_>, state: &AgentOsState, area: Rect) {
    let mut line = vec![
        Span::styled(
            "Tado Agent OS",
            Style::default()
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(
            format!("profile: {}", state.profile),
            Style::default().fg(Color::DarkGray),
        ),
    ];
    if is_power_armed(state) {
        line.push(Span::raw("  "));
        line.push(Span::styled(
            "POWER",
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        ));
    }
    let tabs = Mode::all()
        .iter()
        .flat_map(|(mode, label)| {
            let style = if *mode == state.mode {
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(Color::DarkGray)
            };
            [Span::raw("  "), Span::styled(*label, style)]
        })
        .collect::<Vec<_>>();
    let header = Paragraph::new(vec![
        Line::from(line),
        Line::from(tabs),
        Line::from(Span::styled(
            header_context(state),
            Style::default().fg(Color::DarkGray),
        )),
    ])
    .block(Block::default().borders(Borders::BOTTOM));
    frame.render_widget(header, area);
}

fn draw_work(frame: &mut Frame<'_>, state: &AgentOsState, area: Rect) {
    let body = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(58), Constraint::Percentage(42)])
        .split(area);
    draw_list(frame, state, body[0]);
    draw_inspector(frame, state, body[1]);
}

fn draw_list(frame: &mut Frame<'_>, state: &AgentOsState, area: Rect) {
    let items: Vec<ListItem> = if state.tui.rows.is_empty() {
        vec![ListItem::new("No runtime sessions.")]
    } else {
        state
            .tui
            .rows
            .iter()
            .map(|row| {
                let project = row.project.as_deref().unwrap_or("no project");
                let target = row
                    .target
                    .as_deref()
                    .map(short_id)
                    .unwrap_or_else(|| "-".to_string());
                ListItem::new(Line::from(vec![
                    Span::styled(kind_label(&row.kind), Style::default().fg(Color::Cyan)),
                    Span::raw(" "),
                    Span::styled(target, Style::default().fg(Color::DarkGray)),
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
    if !state.tui.rows.is_empty() {
        list_state.select(Some(state.tui.selected));
    }
    let list = List::new(items)
        .block(Block::default().title("Work").borders(Borders::ALL))
        .highlight_style(
            Style::default()
                .bg(Color::DarkGray)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("> ");
    frame.render_stateful_widget(list, area, &mut list_state);
}

fn draw_inspector(frame: &mut Frame<'_>, state: &AgentOsState, area: Rect) {
    let text = if let Some(row) = state.tui.selected() {
        let target = row.target.as_deref().unwrap_or("none");
        let project = row.project.as_deref().unwrap_or("No project");
        format!(
            "{}\n\nType: {}\nStatus: {}\nProject: {}\nTarget: {}",
            row.title,
            kind_label(&row.kind),
            row.status,
            project,
            target
        )
    } else {
        "No selected row.".to_string()
    };
    let paragraph = Paragraph::new(text)
        .block(Block::default().title("Inspector").borders(Borders::ALL))
        .wrap(Wrap { trim: true });
    frame.render_widget(paragraph, area);
}

fn draw_mux(frame: &mut Frame<'_>, state: &AgentOsState, area: Rect) {
    let body = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(34), Constraint::Percentage(66)])
        .split(area);
    draw_list(frame, state, body[0]);
    let scroll = if state.settings.follow_transcript && state.follow_output {
        bottom_scroll(&state.screen_text, body[1])
    } else {
        state.scroll
    };
    draw_text(
        frame,
        "Selected transcript",
        &state.screen_text,
        body[1],
        scroll,
    );
}

fn draw_board(frame: &mut Frame<'_>, state: &AgentOsState, area: Rect) {
    if state.board_columns.is_empty() {
        let paragraph = Paragraph::new("No Kanban lanes yet.")
            .block(Block::default().title("Smart Kanban").borders(Borders::ALL))
            .wrap(Wrap { trim: true });
        frame.render_widget(paragraph, area);
        return;
    }

    let lane_count = state.board_columns.len().clamp(1, 6);
    let width = (100 / lane_count as u16).max(1);
    let mut constraints = vec![Constraint::Percentage(width); lane_count];
    if state.board_columns.len() > lane_count {
        constraints.push(Constraint::Min(1));
    }
    let lanes = Layout::default()
        .direction(Direction::Horizontal)
        .constraints(constraints)
        .split(area);
    let selected_target = state.tui.selected().and_then(|row| row.target.as_deref());
    let offset = state.scroll as usize;

    for (index, column) in state.board_columns.iter().take(lane_count).enumerate() {
        let visible_cards = column
            .cards
            .iter()
            .filter(|card| state.settings.show_done_cards || !is_done_status(&card.status))
            .collect::<Vec<_>>();
        let items = if visible_cards.is_empty() {
            vec![ListItem::new(Line::from(Span::styled(
                "empty",
                Style::default().fg(Color::DarkGray),
            )))]
        } else {
            visible_cards
                .iter()
                .skip(offset)
                .map(|card| {
                    let selected = selected_target == Some(card.session_id.as_str());
                    let title_style = if selected {
                        Style::default()
                            .fg(Color::Cyan)
                            .add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::White)
                    };
                    if state.settings.compact_board {
                        ListItem::new(Line::from(vec![
                            Span::styled(
                                short_id(&card.session_id),
                                Style::default().fg(Color::DarkGray),
                            ),
                            Span::raw(" "),
                            Span::styled(card.status.as_str(), Style::default().fg(Color::Yellow)),
                            Span::raw(" "),
                            Span::styled(card.title.clone(), title_style),
                        ]))
                    } else {
                        ListItem::new(vec![
                            Line::from(vec![
                                Span::styled(
                                    short_id(&card.session_id),
                                    Style::default().fg(Color::DarkGray),
                                ),
                                Span::raw(" "),
                                Span::styled(
                                    card.status.as_str(),
                                    Style::default().fg(Color::Yellow),
                                ),
                            ]),
                            Line::from(Span::styled(card.title.clone(), title_style)),
                        ])
                    }
                })
                .collect()
        };
        let title = format!("{}  {}", column.title, visible_cards.len());
        let list = List::new(items).block(Block::default().title(title).borders(Borders::ALL));
        frame.render_widget(list, lanes[index]);
    }

    if state.board_columns.len() > lane_count {
        let hidden = state.board_columns.len() - lane_count;
        let note = Paragraph::new(format!("+{hidden} hidden lanes"))
            .style(Style::default().fg(Color::DarkGray))
            .block(Block::default().title("More").borders(Borders::ALL))
            .wrap(Wrap { trim: true });
        frame.render_widget(note, lanes[lane_count]);
    }
}

fn draw_projects(frame: &mut Frame<'_>, state: &AgentOsState, area: Rect) {
    let body = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(36), Constraint::Percentage(64)])
        .split(area);

    let active_root = state.active_project_root.as_deref();
    let items: Vec<ListItem> = if state.projects.is_empty() {
        vec![ListItem::new("No projects in this profile.")]
    } else {
        state
            .projects
            .iter()
            .map(|project| {
                let marker = if active_root == Some(project.root.as_str()) {
                    "*"
                } else {
                    " "
                };
                ListItem::new(vec![
                    Line::from(vec![
                        Span::styled(marker, Style::default().fg(Color::Cyan)),
                        Span::raw(" "),
                        Span::styled(project.name.clone(), Style::default().fg(Color::White)),
                    ]),
                    Line::from(vec![
                        Span::styled(short_id(&project.id), Style::default().fg(Color::DarkGray)),
                        Span::raw(" "),
                        Span::styled(project.root.clone(), Style::default().fg(Color::DarkGray)),
                    ]),
                ])
            })
            .collect()
    };

    let mut list_state = ListState::default();
    if !state.projects.is_empty() {
        list_state.select(Some(state.project_selected.min(state.projects.len() - 1)));
    }
    let project_list = List::new(items)
        .block(Block::default().title("Projects").borders(Borders::ALL))
        .highlight_style(
            Style::default()
                .bg(Color::DarkGray)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("> ");
    frame.render_stateful_widget(project_list, body[0], &mut list_state);

    let detail = if let Some(project) = state.projects.get(state.project_selected) {
        let mut lines = vec![
            Line::from(Span::styled(
                project.name.clone(),
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            )),
            Line::from(vec![
                Span::styled("id: ", Style::default().fg(Color::DarkGray)),
                Span::raw(project.id.clone()),
            ]),
            Line::from(vec![
                Span::styled("root: ", Style::default().fg(Color::DarkGray)),
                Span::raw(project.root.clone()),
            ]),
            Line::from(""),
            Line::from(Span::styled("Tasks", Style::default().fg(Color::Cyan))),
        ];
        let tasks = state
            .tui
            .rows
            .iter()
            .filter(|row| row.project.as_deref() == Some(project.root.as_str()))
            .collect::<Vec<_>>();
        if tasks.is_empty() {
            lines.push(Line::from(Span::styled(
                "No sessions for this project.",
                Style::default().fg(Color::DarkGray),
            )));
        } else {
            for row in tasks {
                let target = row
                    .target
                    .as_deref()
                    .map(short_id)
                    .unwrap_or_else(|| "-".to_string());
                lines.push(Line::from(vec![
                    Span::styled(target, Style::default().fg(Color::DarkGray)),
                    Span::raw(" "),
                    Span::styled(row.status.clone(), Style::default().fg(Color::Yellow)),
                    Span::raw(" "),
                    Span::styled(row.title.clone(), Style::default().fg(Color::White)),
                ]));
            }
        }
        lines
    } else {
        vec![Line::from("No selected project.")]
    };
    let panel = Paragraph::new(detail)
        .block(
            Block::default()
                .title("Project Detail")
                .borders(Borders::ALL),
        )
        .wrap(Wrap { trim: false });
    frame.render_widget(panel, body[1]);
}

fn draw_settings(frame: &mut Frame<'_>, state: &AgentOsState, area: Rect) {
    let body = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(48), Constraint::Percentage(52)])
        .split(area);

    let items = setting_lines(state)
        .into_iter()
        .map(ListItem::new)
        .collect::<Vec<_>>();
    let mut list_state = ListState::default();
    list_state.select(Some(state.settings_selected.min(setting_count() - 1)));
    let list = List::new(items)
        .block(Block::default().title("Settings").borders(Borders::ALL))
        .highlight_style(
            Style::default()
                .bg(Color::DarkGray)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("> ");
    frame.render_stateful_widget(list, body[0], &mut list_state);

    let runtime = Paragraph::new(state.runtime_text.clone())
        .block(Block::default().title("Runtime").borders(Borders::ALL))
        .wrap(Wrap { trim: false });
    frame.render_widget(runtime, body[1]);
}

fn draw_text(frame: &mut Frame<'_>, title: &str, text: &str, area: Rect, scroll: u16) {
    let scroll = scroll.min(bottom_scroll(text, area));
    let paragraph = Paragraph::new(text)
        .block(Block::default().title(title).borders(Borders::ALL))
        .wrap(Wrap { trim: false })
        .scroll((scroll, 0));
    frame.render_widget(paragraph, area);
}

fn refresh(state: &mut AgentOsState) {
    match state.client.call("session.list", json!({})) {
        Ok(response) => {
            state.tui.connection_error = None;
            let mut rows = rows_from_response(&response.data.unwrap_or(json!({})));
            if let Ok(response) = state
                .client
                .call("workflow.list", json!({ "kind": "dispatch" }))
            {
                if let Some(data) = response.data.as_ref() {
                    rows.extend(workflow_rows(data, WorkKind::Dispatch));
                }
            }
            if let Ok(response) = state
                .client
                .call("workflow.list", json!({ "kind": "eternal" }))
            {
                if let Some(data) = response.data.as_ref() {
                    rows.extend(workflow_rows(data, WorkKind::Eternal));
                }
            }
            state.tui.set_rows(rows);
        }
        Err(err) => {
            state.tui.connection_error = Some(err.to_string());
            state.tui.set_rows(Vec::new());
            return;
        }
    }

    if let Some(row) = state.tui.selected() {
        if let Some(target) = &row.target {
            if state.last_target.as_deref() != Some(target.as_str()) {
                state.last_target = Some(target.clone());
                state.follow_output = true;
                state.scroll = 0;
            }
            match row.kind {
                WorkKind::Tile => {
                    if let Ok(response) = state
                        .client
                        .call("transcript.tail", json!({ "target": target, "limit": 500 }))
                    {
                        state.screen_text = format_transcript(
                            response
                                .data
                                .as_ref()
                                .and_then(|d| d.get("chunks"))
                                .and_then(Value::as_array),
                        );
                    }
                }
                WorkKind::Dispatch | WorkKind::Eternal => {
                    state.screen_text = workflow_row_text(row);
                }
                WorkKind::Todo => {}
            }
        }
    }

    state.events_text = state
        .client
        .call("events.list", json!({ "limit": 80 }))
        .ok()
        .and_then(|r| r.data)
        .map(|data| format_events(&data, state.settings.human_events))
        .unwrap_or_default();
    state.board_columns = state
        .client
        .call("kanban.snapshot", json!({}))
        .ok()
        .and_then(|r| r.data)
        .map(parse_board)
        .unwrap_or_default();
    state.runtime_text = state
        .client
        .call("runtime.status", json!({}))
        .ok()
        .and_then(|r| r.data)
        .map(|data| format_runtime_status(&data))
        .unwrap_or_default();
    if let Ok(response) = state.client.call("project.status", json!({})) {
        if let Some(data) = response.data {
            update_projects_from_data(state, &data);
        }
    }
}

fn rows_from_response(data: &Value) -> Vec<WorkRow> {
    let Some(sessions) = data.get("sessions").and_then(Value::as_array) else {
        return Vec::new();
    };
    sessions
        .iter()
        .map(|session| {
            let id = str_field(session, "id").unwrap_or_default().to_string();
            WorkRow {
                id: format!("session:{id}"),
                kind: WorkKind::Tile,
                title: str_field(session, "title")
                    .unwrap_or("Untitled session")
                    .to_string(),
                status: str_field(session, "status")
                    .unwrap_or("running")
                    .to_string(),
                project: non_empty(str_field(session, "project_root")),
                target: Some(id),
                promptable: str_field(session, "status")
                    .map(|s| matches!(s, "running" | "waiting"))
                    .unwrap_or(true),
                created_at: parse_timestamp(str_field(session, "created_at")),
            }
        })
        .collect()
}

fn workflow_rows(data: &Value, kind: WorkKind) -> Vec<WorkRow> {
    let Some(runs) = data.get("runs").and_then(Value::as_array) else {
        return Vec::new();
    };
    runs.iter()
        .map(|run| {
            let id = str_field(run, "id").unwrap_or_default().to_string();
            let state = str_field(run, "state").unwrap_or("drafting");
            let feature = str_field(run, "feature").unwrap_or("Untitled workflow");
            let mode = str_field(run, "mode").unwrap_or("default");
            let layout = str_field(run, "layout").unwrap_or("grid");
            let title = match &kind {
                WorkKind::Dispatch => {
                    format!(
                        "Dispatch · {} · {} · {}",
                        mode.to_ascii_uppercase(),
                        layout,
                        feature
                    )
                }
                WorkKind::Eternal => format!("Eternal · {} · {}", mode, feature),
                WorkKind::Tile | WorkKind::Todo => feature.to_string(),
            };
            WorkRow {
                id: format!("workflow:{id}"),
                kind: kind.clone(),
                title,
                status: state.to_string(),
                project: non_empty(str_field(run, "project")),
                target: Some(id),
                promptable: !is_done_status(state),
                created_at: parse_timestamp(str_field(run, "created_at")),
            }
        })
        .collect()
}

fn submit(state: &mut AgentOsState) {
    let message = state.tui.draft.trim().to_string();
    if message.is_empty() {
        return;
    }
    let result = if message.starts_with('/') {
        run_operator_command(state, &message)
    } else if state.mode == Mode::Projects {
        spawn_selected_project_prompt(state, &message)
    } else {
        send_current(state, &message)
    };

    match result {
        Ok(status) => {
            state.tui.draft.clear();
            state.tui.status = Some(status);
            state.suggestion_selected = 0;
        }
        Err(err) => {
            state.tui.status = Some(err.to_string());
        }
    }
}

fn run_operator_command(state: &mut AgentOsState, command: &str) -> Result<String> {
    let mut parts = command.split_whitespace();
    let verb = parts.next().unwrap_or("");
    let rest = parts.collect::<Vec<_>>().join(" ");
    match verb {
        "/spawn" => spawn_engine(state, "shell", &rest),
        "/codex" => spawn_engine(state, "codex", &rest),
        "/bootstrap" => {
            let mut args = rest.split_whitespace();
            let action = args.next().unwrap_or("");
            if action.is_empty() {
                return Ok("Usage: /bootstrap a2a|team|auto-mode|knowledge|index".to_string());
            }
            let engine = args.next().unwrap_or("codex");
            let response = state.client.call(
                "bootstrap.request",
                json!({ "action": action, "engine": engine, "project_root": state.active_project_root }),
            )?;
            Ok(format!(
                "Bootstrap requested {}",
                response_id(&response.data)
            ))
        }
        "/dispatch" => dispatch_command(state, &rest),
        "/project" | "/projects" => project_command(state, &rest),
        "/move" => {
            let mut args = rest.split_whitespace().collect::<Vec<_>>();
            if args.is_empty() {
                return Ok("Usage: /move [session] <lane>".to_string());
            }
            let lane = args.pop().unwrap_or_default();
            let target = if args.is_empty() {
                explicit_or_selected("", state)?.to_string()
            } else {
                args.join(" ")
            };
            let response = state
                .client
                .call("kanban.move", json!({ "target": target, "lane": lane }))?;
            Ok(format!("Moved {}", response_id(&response.data)))
        }
        "/lane" => {
            let mut args = rest.splitn(2, ' ');
            let key = args.next().unwrap_or("").trim();
            let title = args.next().unwrap_or("").trim();
            if key.is_empty() || title.is_empty() {
                return Ok("Usage: /lane <key> <title>".to_string());
            }
            state
                .client
                .call("kanban.add_column", json!({ "key": key, "title": title }))?;
            Ok(format!("Added lane {key}."))
        }
        "/broadcast" => {
            if rest.trim().is_empty() {
                return Ok("Usage: /broadcast <message>".to_string());
            }
            let response = state.client.call(
                "session.broadcast",
                json!({ "message": rest, "enter": true }),
            )?;
            Ok(format!("Broadcast {}", response_id(&response.data)))
        }
        "/notify" => {
            if rest.trim().is_empty() {
                return Ok("Usage: /notify <title>".to_string());
            }
            let response = state
                .client
                .call("events.notify", json!({ "title": rest }))?;
            Ok(format!("Notified {}", response_id(&response.data)))
        }
        "/stop" => {
            let target = explicit_or_selected(&rest, state)?;
            let response = state
                .client
                .call("session.kill", json!({ "target": target, "hard": false }))?;
            Ok(format!("Stopped {}", response_id(&response.data)))
        }
        "/hard-kill" => {
            require_power(state)?;
            let target = explicit_or_selected(&rest, state)?;
            let response = state
                .client
                .call("session.kill", json!({ "target": target, "hard": true }))?;
            Ok(format!("Hard killed {}", response_id(&response.data)))
        }
        "/delete" => {
            let target = explicit_or_selected(&rest, state)?;
            let response = state
                .client
                .call("session.delete", json!({ "target": target, "hard": true }))?;
            Ok(format!("Deleted {}", response_id(&response.data)))
        }
        "/shutdown" => {
            require_power(state)?;
            state.client.call("daemon.shutdown", json!({}))?;
            Ok("Runtime daemon shutdown requested.".to_string())
        }
        "/power" => {
            if rest == "tado-power" {
                state.power_armed_until = Some(Instant::now() + Duration::from_secs(300));
                Ok("Power mode armed for 5 minutes.".to_string())
            } else {
                Ok("Type /power tado-power to arm hard-kill and daemon shutdown.".to_string())
            }
        }
        "/search" => {
            let response = state
                .client
                .call("transcript.search", json!({ "query": rest, "limit": 20 }))?;
            Ok(format_json_lines(
                response
                    .data
                    .as_ref()
                    .and_then(|d| d.get("matches"))
                    .and_then(Value::as_array),
            ))
        }
        "/help" => Ok(use_text().to_string()),
        _ => Ok("Unknown command. Type / to open autocomplete or /help for commands.".to_string()),
    }
}

fn spawn_engine(state: &mut AgentOsState, engine: &str, text: &str) -> Result<String> {
    if text.trim().is_empty() {
        return Ok(format!("Usage: /{engine} <prompt or command>"));
    }
    let cwd = state.active_project_root.clone().or_else(|| {
        std::env::current_dir()
            .ok()
            .map(|p| p.display().to_string())
    });
    let response = state.client.call(
        "session.spawn",
        json!({
            "engine": engine,
            "prompt": text,
            "command": text,
            "cwd": cwd,
            "project_root": state.active_project_root.clone(),
            "flags": spawn_flags_for_engine(&state.settings, engine),
            "env": spawn_env_for_engine(&state.settings, engine),
        }),
    )?;
    Ok(format!("Spawned {}", response_id(&response.data)))
}

fn dispatch_command(state: &mut AgentOsState, rest: &str) -> Result<String> {
    let mut parts = rest.split_whitespace();
    let action = parts.next().unwrap_or("");
    match action {
        "start" => {
            let args = parts.collect::<Vec<_>>();
            let (execution_type, layout, brief) = parse_dispatch_start_args(&args);
            if brief.trim().is_empty() {
                return Ok("Usage: /dispatch start --type wave --layout grid <brief>".to_string());
            }
            let project = state
                .active_project_root
                .clone()
                .or_else(|| {
                    state
                        .projects
                        .get(state.project_selected)
                        .map(|p| p.root.clone())
                })
                .or_else(|| {
                    std::env::current_dir()
                        .ok()
                        .map(|path| path.display().to_string())
                });
            let engine = DEFAULT_ENGINES
                .get(state.settings.default_engine)
                .copied()
                .unwrap_or("codex");
            let feature = workflow_title_from_brief(&brief);
            let coordinator_todo_id = format!(
                "tui-{}",
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|duration| duration.as_nanos())
                    .unwrap_or_default()
            );
            let response = state.client.call(
                "workflow.propose",
                json!({
                    "kind": "dispatch",
                    "project": project,
                    "feature": feature.clone(),
                    "task": brief,
                    "mode": execution_type,
                    "layout": layout,
                    "engine": engine,
                    "coordinator_todo_id": coordinator_todo_id,
                    "label": feature,
                }),
            )?;
            Ok(format!(
                "Dispatch proposed {}",
                response_run_id(&response.data)
            ))
        }
        "list" => {
            let response = state
                .client
                .call("workflow.list", json!({ "kind": "dispatch" }))?;
            Ok(format_workflow_list(response.data.as_ref()))
        }
        "status" => {
            let run_id = parts.next().unwrap_or("");
            if run_id.is_empty() {
                return Ok("Usage: /dispatch status <run_id>".to_string());
            }
            let response = state
                .client
                .call("workflow.status", json!({ "run_id": run_id }))?;
            Ok(serde_json::to_string_pretty(
                &response.data.unwrap_or(json!({})),
            )?)
        }
        "crafted" => {
            let run_id = parts.next().unwrap_or("");
            if run_id.is_empty() {
                return Ok("Usage: /dispatch crafted <run_id>".to_string());
            }
            let response = state
                .client
                .call("workflow.crafted", json!({ "run_id": run_id }))?;
            Ok(response
                .data
                .as_ref()
                .and_then(|data| str_field(data, "crafted"))
                .unwrap_or("")
                .to_string())
        }
        "accept" => {
            let run_id = parts.next().unwrap_or("");
            if run_id.is_empty() {
                return Ok("Usage: /dispatch accept <run_id>".to_string());
            }
            let note = parts.collect::<Vec<_>>().join(" ");
            let response = state.client.call(
                "workflow.accept",
                json!({ "run_id": run_id, "note": non_empty(Some(&note)) }),
            )?;
            Ok(format!(
                "Dispatch accepted {}",
                response_run_id(&response.data)
            ))
        }
        "reject" => {
            let args = parts.collect::<Vec<_>>();
            if args.is_empty() {
                return Ok("Usage: /dispatch reject <run_id> --reason <text>".to_string());
            }
            let run_id = args[0];
            let reason = parse_reason_arg(&args[1..]);
            if reason.trim().is_empty() {
                return Ok("Usage: /dispatch reject <run_id> --reason <text>".to_string());
            }
            state.client.call(
                "workflow.reject",
                json!({ "run_id": run_id, "reason": reason }),
            )?;
            Ok(format!("Dispatch rejected {}", short_id(run_id)))
        }
        "" => Ok("Usage: /dispatch start|list|status|crafted|accept|reject".to_string()),
        _ => Ok("Usage: /dispatch start|list|status|crafted|accept|reject".to_string()),
    }
}

fn parse_dispatch_start_args(args: &[&str]) -> (String, String, String) {
    let mut execution_type = "sequential".to_string();
    let mut layout = "grid".to_string();
    let mut brief = Vec::new();
    let mut index = 0;
    while index < args.len() {
        match args[index] {
            "--type" if index + 1 < args.len() => {
                execution_type = if args[index + 1].eq_ignore_ascii_case("wave") {
                    "wave".to_string()
                } else {
                    "sequential".to_string()
                };
                index += 2;
            }
            "--layout" if index + 1 < args.len() => {
                layout = if args[index + 1].eq_ignore_ascii_case("kanban") {
                    "kanban".to_string()
                } else {
                    "grid".to_string()
                };
                index += 2;
            }
            other => {
                brief.push(other);
                index += 1;
            }
        }
    }
    (execution_type, layout, brief.join(" "))
}

fn parse_reason_arg(args: &[&str]) -> String {
    let mut reason = Vec::new();
    let mut index = 0;
    while index < args.len() {
        if args[index] == "--reason" {
            reason.extend_from_slice(&args[index + 1..]);
            break;
        }
        index += 1;
    }
    reason.join(" ")
}

fn workflow_title_from_brief(brief: &str) -> String {
    let line = brief.lines().next().unwrap_or(brief).trim();
    let title = line.chars().take(60).collect::<String>();
    if title.is_empty() {
        "Dispatch".to_string()
    } else {
        title
    }
}

fn project_command(state: &mut AgentOsState, rest: &str) -> Result<String> {
    let mut parts = rest.split_whitespace();
    let action = parts.next().unwrap_or("status");
    match action {
        "status" => {
            let response = state.client.call("project.status", json!({}))?;
            let text = if let Some(data) = response.data.as_ref() {
                update_projects_from_data(state, data);
                format_projects(data)
            } else {
                String::new()
            };
            Ok(text)
        }
        "list" => {
            let response = state.client.call("project.list", json!({}))?;
            let text = if let Some(data) = response.data.as_ref() {
                update_projects_from_data(state, data);
                format_projects(data)
            } else {
                String::new()
            };
            Ok(text)
        }
        "add" | "create" => {
            let root = parts.next().unwrap_or("");
            if root.is_empty() {
                return Ok(
                    "Usage: /project add <path> [name] or /project create <path> [name]"
                        .to_string(),
                );
            }
            let name = {
                let rest = parts.collect::<Vec<_>>().join(" ");
                if rest.trim().is_empty() {
                    None
                } else {
                    Some(rest)
                }
            };
            let response = state.client.call(
                "project.add",
                json!({
                    "root": root,
                    "name": name,
                    "create": action == "create",
                    "activate": true,
                }),
            )?;
            if let Some(data) = response.data.as_ref() {
                state.active_project_root = data
                    .get("active")
                    .and_then(|active| active.get("root"))
                    .and_then(Value::as_str)
                    .map(str::to_string);
            }
            refresh_projects(state)?;
            Ok(format!(
                "Active project: {}",
                state.active_project_root.as_deref().unwrap_or("none")
            ))
        }
        "use" => {
            let target = parts.collect::<Vec<_>>().join(" ");
            if target.trim().is_empty() {
                return Ok("Usage: /project use <name|path|id>".to_string());
            }
            let response = state
                .client
                .call("project.use", json!({ "target": target.trim() }))?;
            state.active_project_root = response
                .data
                .as_ref()
                .and_then(|data| data.get("active"))
                .and_then(|active| active.get("root"))
                .and_then(Value::as_str)
                .map(str::to_string);
            refresh_projects(state)?;
            Ok(format!(
                "Active project: {}",
                state.active_project_root.as_deref().unwrap_or("none")
            ))
        }
        _ => Ok(
            "Usage: /project status|list|add <path> [name]|create <path> [name]|use <target>"
                .to_string(),
        ),
    }
}

fn refresh_projects(state: &mut AgentOsState) -> Result<()> {
    let response = state.client.call("project.status", json!({}))?;
    if let Some(data) = response.data {
        update_projects_from_data(state, &data);
    }
    Ok(())
}

fn update_projects_from_data(state: &mut AgentOsState, data: &Value) {
    let previous_selected_root = state
        .projects
        .get(state.project_selected)
        .map(|project| project.root.clone());
    let active_root = data
        .get("active")
        .and_then(|active| active.get("root"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let projects = parse_projects(data);
    let selected = previous_selected_root
        .as_ref()
        .and_then(|root| projects.iter().position(|project| project.root == *root))
        .or_else(|| {
            active_root
                .as_ref()
                .and_then(|root| projects.iter().position(|project| project.root == *root))
        })
        .unwrap_or(0);

    state.projects = projects;
    state.active_project_root = active_root;
    state.project_selected = if state.projects.is_empty() {
        0
    } else {
        selected.min(state.projects.len() - 1)
    };
}

fn parse_projects(data: &Value) -> Vec<ProjectView> {
    data.get("projects")
        .and_then(Value::as_array)
        .map(|projects| {
            projects
                .iter()
                .filter_map(|project| {
                    let id = str_field(project, "id")?.to_string();
                    let root = str_field(project, "root")?.to_string();
                    let name = str_field(project, "name").unwrap_or("unnamed").to_string();
                    Some(ProjectView { id, name, root })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn load_settings(state: &mut AgentOsState) {
    let Ok(response) = state.client.call("settings.get", json!({})) else {
        return;
    };
    let Some(settings) = response.data.and_then(|data| data.get("settings").cloned()) else {
        return;
    };
    if settings.is_null() {
        return;
    }
    if let Ok(mut parsed) = serde_json::from_value::<UiSettings>(settings) {
        clamp_settings(&mut parsed);
        state.settings = parsed;
    }
}

fn save_settings(state: &AgentOsState) -> Result<()> {
    state
        .client
        .call("settings.set", json!({ "settings": state.settings }))?;
    Ok(())
}

fn clamp_settings(settings: &mut UiSettings) {
    settings.default_engine = if settings.default_engine == 0 { 0 } else { 1 };
    settings.codex_mode = settings.codex_mode.min(CODEX_MODES.len() - 1);
    settings.codex_model = settings.codex_model.min(CODEX_MODELS.len() - 1);
    settings.codex_effort = settings.codex_effort.min(CODEX_EFFORTS.len() - 1);
    if settings.codex_account_label.trim().is_empty() {
        settings.codex_account_label = "default".to_string();
    }
    settings.advisor_executioner_engine = 0;
    settings.advisor_executioner_codex_mode = settings
        .advisor_executioner_codex_mode
        .min(CODEX_MODES.len() - 1);
    settings.advisor_executioner_codex_model = settings
        .advisor_executioner_codex_model
        .min(CODEX_MODELS.len() - 1);
    settings.advisor_executioner_codex_effort = settings
        .advisor_executioner_codex_effort
        .min(CODEX_EFFORTS.len() - 1);
    settings.advisor_advisor_engine = 0;
    settings.advisor_advisor_codex_mode = settings
        .advisor_advisor_codex_mode
        .min(CODEX_MODES.len() - 1);
    settings.advisor_advisor_codex_model = settings
        .advisor_advisor_codex_model
        .min(CODEX_MODELS.len() - 1);
    settings.advisor_advisor_codex_effort = settings
        .advisor_advisor_codex_effort
        .min(CODEX_EFFORTS.len() - 1);
    settings.default_theme = settings.default_theme.min(THEMES.len() - 1);
    settings.terminal_font_size = settings.terminal_font_size.clamp(9, 24);
    settings.bell_mode = settings.bell_mode.min(BELL_MODES.len() - 1);
    settings.grid_columns = settings.grid_columns.clamp(1, 8);
}

fn spawn_flags_for_engine(settings: &UiSettings, engine: &str) -> Vec<String> {
    match engine {
        "codex" => codex_flags(
            settings.codex_alternate_screen,
            settings.codex_mode,
            settings.codex_model,
            settings.codex_effort,
        ),
        _ => Vec::new(),
    }
}

fn advisor_engine(_settings: &UiSettings, _role: AdvisorRole) -> &'static str {
    "codex"
}

fn spawn_flags_for_advisor_role(settings: &UiSettings, role: AdvisorRole) -> Vec<String> {
    match role {
        AdvisorRole::Executioner => codex_flags(
            settings.codex_alternate_screen,
            settings.advisor_executioner_codex_mode,
            settings.advisor_executioner_codex_model,
            settings.advisor_executioner_codex_effort,
        ),
        AdvisorRole::Advisor => codex_flags(
            settings.codex_alternate_screen,
            settings.advisor_advisor_codex_mode,
            settings.advisor_advisor_codex_model,
            settings.advisor_advisor_codex_effort,
        ),
    }
}

fn codex_flags(alternate_screen: bool, mode: usize, model: usize, effort: usize) -> Vec<String> {
    let mut flags = Vec::new();
    if !alternate_screen {
        flags.push("--no-alt-screen".to_string());
    }
    flags.extend([
        "-c".to_string(),
        "shell_environment_policy.inherit=all".to_string(),
    ]);
    flags.extend(CODEX_MODES[mode].1.iter().map(|value| value.to_string()));
    flags.extend([
        "-c".to_string(),
        format!("model=\"{}\"", CODEX_MODELS[model].1),
    ]);
    if let Some(effort) = CODEX_EFFORTS[effort].1 {
        flags.extend([
            "-c".to_string(),
            format!("model_reasoning_effort=\"{effort}\""),
        ]);
    }
    flags
}

fn spawn_env_for_engine(_settings: &UiSettings, _engine: &str) -> Vec<(String, String)> {
    Vec::new()
}

fn initialize_advisor_defaults(settings: &mut UiSettings) {
    if settings.advisor_defaults_initialized {
        return;
    }
    settings.advisor_executioner_engine = 0;
    settings.advisor_executioner_codex_mode = settings.codex_mode;
    settings.advisor_executioner_codex_model = settings.codex_model;
    settings.advisor_executioner_codex_effort = settings.codex_effort;
    settings.advisor_advisor_engine = 0;
    settings.advisor_advisor_codex_mode = 0;
    settings.advisor_advisor_codex_model = 0;
    settings.advisor_advisor_codex_effort = 3;
    settings.advisor_defaults_initialized = true;
}

fn move_project_selection(state: &mut AgentOsState, delta: isize) {
    let len = state.projects.len();
    if len == 0 {
        state.project_selected = 0;
        return;
    }
    let current = state.project_selected.min(len - 1) as isize;
    state.project_selected = (current + delta).rem_euclid(len as isize) as usize;
}

fn activate_selected_project(state: &mut AgentOsState) -> Result<String> {
    let project = state
        .projects
        .get(state.project_selected)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("No selected project."))?;
    state
        .client
        .call("project.use", json!({ "target": project.id }))?;
    refresh_projects(state)?;
    Ok(format!("Active project: {}", project.root))
}

fn spawn_selected_project_prompt(state: &mut AgentOsState, text: &str) -> Result<String> {
    let project = state
        .projects
        .get(state.project_selected)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("No selected project."))?;
    if state.settings.auto_activate_project {
        state
            .client
            .call("project.use", json!({ "target": project.id.clone() }))?;
        state.active_project_root = Some(project.root.clone());
    }
    let engine = DEFAULT_ENGINES
        .get(state.settings.default_engine)
        .copied()
        .unwrap_or("codex");
    if state.settings.advisor_enabled {
        initialize_advisor_defaults(&mut state.settings);
        save_settings(state)?;
        let executioner_engine = advisor_engine(&state.settings, AdvisorRole::Executioner);
        let executioner = state.client.call(
            "session.spawn",
            json!({
                "engine": executioner_engine,
                "prompt": advisor_executioner_prompt(text),
                "command": text,
                "cwd": project.root.clone(),
                "project_id": project.id.clone(),
                "project_root": project.root.clone(),
                "title": prompt_title(executioner_engine, text),
                "flags": spawn_flags_for_advisor_role(&state.settings, AdvisorRole::Executioner),
                "env": spawn_env_for_engine(&state.settings, executioner_engine),
            }),
        )?;
        let executioner_id = response_session_id(&executioner.data).ok_or_else(|| {
            anyhow::anyhow!("executioner spawn response did not include a session id")
        })?;
        let executioner_grid =
            response_grid(&executioner.data).unwrap_or_else(|| executioner_id.clone());
        let advisor_engine = advisor_engine(&state.settings, AdvisorRole::Advisor);
        let advisor = state.client.call(
            "session.spawn",
            json!({
                "engine": advisor_engine,
                "prompt": advisor_prompt(text, &executioner_id, &executioner_grid),
                "command": text,
                "cwd": project.root.clone(),
                "project_id": project.id.clone(),
                "project_root": project.root.clone(),
                "title": format!("Advisor: {}", text.chars().take(72).collect::<String>()),
                "flags": spawn_flags_for_advisor_role(&state.settings, AdvisorRole::Advisor),
                "env": spawn_env_for_engine(&state.settings, advisor_engine),
            }),
        )?;
        let advisor_id = response_session_id(&advisor.data).ok_or_else(|| {
            anyhow::anyhow!("advisor spawn response did not include a session id")
        })?;
        state.client.call(
            "advisor.link",
            json!({
                "executioner_id": executioner_id,
                "advisor_id": advisor_id,
            }),
        )?;
        return Ok(format!(
            "Spawned advisor pair {} + {} in {}",
            response_id(&executioner.data),
            response_id(&advisor.data),
            project.name
        ));
    }
    let response = state.client.call(
        "session.spawn",
        json!({
            "engine": engine,
            "prompt": text,
            "command": text,
            "cwd": project.root.clone(),
            "project_id": project.id.clone(),
            "project_root": project.root.clone(),
            "title": prompt_title(engine, text),
            "flags": spawn_flags_for_engine(&state.settings, engine),
            "env": spawn_env_for_engine(&state.settings, engine),
        }),
    )?;
    Ok(format!(
        "Spawned {} in {}",
        response_id(&response.data),
        project.name
    ))
}

fn send_current(state: &mut AgentOsState, message: &str) -> Result<String> {
    let target = state
        .tui
        .send_target()
        .ok_or_else(|| anyhow::anyhow!("Selected row cannot receive a prompt."))?;
    match target {
        SendTarget::Tile { target } => {
            state.client.call(
                "session.send",
                json!({ "target": target, "message": message, "enter": true }),
            )?;
            Ok("Sent.".to_string())
        }
        SendTarget::Dispatch { run_id } => {
            state.client.call(
                "workflow.accept",
                json!({ "run_id": run_id, "note": message }),
            )?;
            Ok("Dispatch accepted.".to_string())
        }
        SendTarget::Eternal { run_id } => {
            state.client.call(
                "workflow.accept",
                json!({ "run_id": run_id, "note": message }),
            )?;
            Ok("Eternal accepted.".to_string())
        }
    }
}

fn delete_selected_work(state: &mut AgentOsState) -> Result<String> {
    let row = state
        .tui
        .selected()
        .ok_or_else(|| anyhow::anyhow!("No selected task or session."))?;
    let target = row
        .target
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("Selected item cannot be deleted from the runtime."))?
        .to_string();
    state
        .client
        .call("session.delete", json!({ "target": target, "hard": true }))?;
    Ok("Deleted selected session.".to_string())
}

fn explicit_or_selected<'a>(rest: &'a str, state: &'a AgentOsState) -> Result<&'a str> {
    if !rest.trim().is_empty() {
        return Ok(rest.trim());
    }
    state
        .tui
        .selected()
        .and_then(|row| row.target.as_deref())
        .ok_or_else(|| anyhow::anyhow!("No target provided and no row selected."))
}

fn require_power(state: &AgentOsState) -> Result<()> {
    if is_power_armed(state) {
        Ok(())
    } else {
        Err(anyhow::anyhow!(
            "Power mode is not armed. Type /power tado-power first."
        ))
    }
}

fn is_power_armed(state: &AgentOsState) -> bool {
    state
        .power_armed_until
        .map(|deadline| Instant::now() < deadline)
        .unwrap_or(false)
}

fn response_id(data: &Option<Value>) -> String {
    data.as_ref()
        .and_then(|d| {
            d.get("session_id")
                .or_else(|| d.get("session").and_then(|s| s.get("id")))
        })
        .and_then(Value::as_str)
        .map(short_id)
        .unwrap_or_else(|| "session".to_string())
}

fn response_session_id(data: &Option<Value>) -> Option<String> {
    data.as_ref()
        .and_then(|d| {
            d.get("session_id")
                .or_else(|| d.get("session").and_then(|s| s.get("id")))
        })
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn response_grid(data: &Option<Value>) -> Option<String> {
    let session = data.as_ref()?.get("session")?;
    let row = session.get("grid_row")?.as_i64()?;
    let col = session.get("grid_col")?.as_i64()?;
    Some(format!("[{row}, {col}]"))
}

fn advisor_executioner_prompt(task: &str) -> String {
    format!(
        "You are the executioner in Tado Advisor mode.\n\nUser task:\n{task}\n\nRules:\n- Do not plan the whole task.\n- Wait for the advisor.\n- Execute exactly one advisor step at a time.\n- Keep replies short: result, key output, blocker.\n- Do not ask the user unless the advisor tells you to.\n\nReply with: READY"
    )
}

fn advisor_prompt(task: &str, executioner_id: &str, executioner_grid: &str) -> String {
    format!(
        "You are the advisor in Tado Advisor mode.\n\nUser task:\n{task}\n\nExecutioner:\n- UUID: {executioner_id}\n- Grid: {executioner_grid}\n\nWorkflow:\n- You decide the plan.\n- The executioner does the work.\n- Send one tiny step at a time.\n- Prefer under 240 characters.\n- Wait for relay output before the next step.\n- Prefer `tado_send` / `tado_read` MCP tools if available.\n- Otherwise use `tado-send {executioner_id} \"<step>\"` and `tado-read {executioner_id} --tail 80`.\n- Do not edit files, run tests, or execute project commands yourself.\n- If relay output is clipped, ask with `tado-read {executioner_id} --tail 160`.\n\nFirst step: tell the executioner the smallest useful action."
    )
}

fn response_run_id(data: &Option<Value>) -> String {
    data.as_ref()
        .and_then(|d| {
            d.get("run")
                .and_then(|run| run.get("id"))
                .or_else(|| d.get("run_id"))
        })
        .and_then(Value::as_str)
        .map(short_id)
        .unwrap_or_else(|| "run".to_string())
}

fn workflow_row_text(row: &WorkRow) -> String {
    format!(
        "{}\nStatus: {}\nProject: {}\nRun: {}\n\nType a note and press Enter to accept or continue this workflow, or use /dispatch commands for explicit control.",
        row.title,
        row.status,
        row.project.as_deref().unwrap_or("none"),
        row.target.as_deref().unwrap_or("")
    )
}

fn format_workflow_list(data: Option<&Value>) -> String {
    let runs = data
        .and_then(|data| data.get("runs"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if runs.is_empty() {
        return "No Dispatch runs.".to_string();
    }
    runs.iter()
        .map(|run| {
            let id = short_id(str_field(run, "id").unwrap_or(""));
            let state = str_field(run, "state").unwrap_or("drafting");
            let mode = str_field(run, "mode").unwrap_or("sequential");
            let layout = str_field(run, "layout").unwrap_or("grid");
            let feature = str_field(run, "feature").unwrap_or("Untitled");
            format!("{id}  {state:<12} {mode:<10} {layout:<6} {feature}")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn parse_board(data: Value) -> Vec<KanbanColumn> {
    let columns = data
        .get("columns")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let cards = data
        .get("cards")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    columns
        .into_iter()
        .map(|column| {
            let key = str_field(&column, "key").unwrap_or("");
            let title = str_field(&column, "title").unwrap_or(key);
            let cards = cards
                .iter()
                .filter(|card| str_field(card, "lane") == Some(key))
                .map(|card| KanbanCard {
                    session_id: str_field(card, "session_id").unwrap_or("").to_string(),
                    title: str_field(card, "title").unwrap_or("Untitled").to_string(),
                    status: str_field(card, "status").unwrap_or("").to_string(),
                })
                .collect();
            KanbanColumn {
                key: key.to_string(),
                title: title.to_string(),
                cards,
            }
        })
        .collect()
}

fn format_json_lines(values: Option<&Vec<Value>>) -> String {
    values
        .map(|items| {
            items
                .iter()
                .map(|item| serde_json::to_string(item).unwrap_or_default())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn format_transcript(values: Option<&Vec<Value>>) -> String {
    values
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let stream = str_field(item, "stream").unwrap_or("out");
                    let chunk = str_field(item, "chunk").unwrap_or("");
                    if chunk.is_empty() {
                        None
                    } else if matches!(stream, "stdout" | "screen") {
                        Some(chunk.to_string())
                    } else {
                        Some(format!("[{stream}] {chunk}"))
                    }
                })
                .collect::<Vec<_>>()
                .join("")
        })
        .unwrap_or_default()
}

fn format_events(data: &Value, human: bool) -> String {
    let events = data.get("events").and_then(Value::as_array);
    if !human {
        return format_json_lines(events);
    }
    let Some(events) = events else {
        return String::new();
    };
    if events.is_empty() {
        return "No timeline events yet.".to_string();
    }
    events
        .iter()
        .map(|event| {
            let time = event_time(str_field(event, "created_at"));
            let kind = str_field(event, "kind").unwrap_or("event");
            let label = event_kind_label(kind);
            let message = str_field(event, "message").unwrap_or("");
            let subject = str_field(event, "subject_id").map(short_id);
            let payload = event_payload_summary(event.get("payload"));
            let mut lines = vec![format!("{time}  {label}")];
            if !message.is_empty() {
                lines.push(format!("  {message}"));
            }
            if let Some(subject) = subject {
                lines.push(format!("  target {subject}"));
            }
            if let Some(payload) = payload {
                lines.push(format!("  {payload}"));
            }
            lines.join("\n")
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn event_time(value: Option<&str>) -> String {
    value
        .and_then(|time| DateTime::parse_from_rfc3339(time).ok())
        .map(|time| time.format("%m-%d %H:%M:%S").to_string())
        .unwrap_or_else(|| "-- --:--:--".to_string())
}

fn event_kind_label(kind: &str) -> String {
    match kind {
        "session.spawned" => "Spawned session",
        "session.sent" => "Sent message",
        "session.exited" => "Session exited",
        "session.killed" => "Session stopped",
        "session.deleted" => "Session deleted",
        "project.added" => "Added project",
        "project.selected" => "Selected project",
        "settings.updated" => "Settings updated",
        "advisor.linked" => "Advisor linked",
        "advisor.relayed" => "Advisor relay",
        "kanban.moved" => "Moved card",
        "kanban.column_added" => "Added lane",
        "bootstrap.requested" => "Bootstrap requested",
        "daemon.shutdown_requested" => "Shutdown requested",
        "daemon.shutdown" => "Runtime stopped",
        "user.broadcast" => "Notice",
        other => other,
    }
    .to_string()
}

fn event_payload_summary(payload: Option<&Value>) -> Option<String> {
    let payload = payload?;
    if payload.is_null() {
        return None;
    }
    if let Some(project) = payload.get("project") {
        let name = str_field(project, "name").unwrap_or("unnamed");
        let root = str_field(project, "root").unwrap_or("");
        return Some(format!("project {name}  {root}"));
    }
    if let Some(title) = str_field(payload, "title") {
        let body = str_field(payload, "body").unwrap_or("");
        return Some(if body.is_empty() {
            title.to_string()
        } else {
            format!("{title}: {body}")
        });
    }
    if let Some(engine) = str_field(payload, "engine") {
        let cwd = str_field(payload, "cwd").unwrap_or("");
        return Some(format!("engine {engine}  {cwd}"));
    }
    None
}

fn format_runtime_status(data: &Value) -> String {
    let profile = str_field(data, "profile").unwrap_or("unknown");
    let runtime = str_field(data, "runtime_id")
        .map(short_id)
        .unwrap_or_default();
    let socket = str_field(data, "socket").unwrap_or("");
    let db = str_field(data, "db").unwrap_or("");
    let schema = data
        .get("schema_version")
        .and_then(Value::as_i64)
        .map(|version| version.to_string())
        .unwrap_or_else(|| "unknown".to_string());
    let live = data
        .get("live_sessions")
        .and_then(Value::as_u64)
        .map(|count| count.to_string())
        .unwrap_or_else(|| "0".to_string());
    let active_project = data
        .get("active_project")
        .filter(|value| !value.is_null())
        .and_then(|project| str_field(project, "root"))
        .unwrap_or("none");
    format!(
        "Profile: {profile}\nRuntime: {runtime}\nLive sessions: {live}\nSchema: {schema}\nActive project: {active_project}\n\nSocket:\n{socket}\n\nDatabase:\n{db}"
    )
}

fn use_text() -> &'static str {
    "Operator commands:\n\n/spawn <shell command>\n/codex <prompt>\n/project or /projects status|list|add|create|use\n/bootstrap <action> [engine]\n/dispatch start --type wave --layout grid <brief>\n/dispatch list|status|crafted|accept|reject\n/move [session] <lane>\n/lane <key> <title>\n/broadcast <message>\n/notify <title>\n/stop [session]\n/hard-kill [session]\n/delete [session]\n/search <text>\n/power tado-power\n/shutdown\n/help\n\nPages:\nShift+1..7 jumps to a page. Tab and Shift-Tab move through pages.\nType / to open commands. Up/Down chooses a command. Enter completes it.\nPgUp/PgDn and Ctrl-U/Ctrl-D scroll. End follows the selected transcript.\nShift+X deletes the selected runtime session.\n\nProject workflow:\nOn Projects, Up/Down selects a project. Space makes it active.\nTyping normal prompt text on Projects spawns the default Codex agent directly in the selected project. If Advisor mode is on, it spawns a Codex executioner plus a Codex advisor instead.\nPlain paths like Documents/app, downloads/app, or my-app resolve from your home folder.\n\nSettings:\nUp/Down selects a setting. Space or Right advances it. Left moves backward.\nCodex model, effort, permission mode, account label, Advisor role profiles, terminal display, board, events, and project prompt behavior are all changed here.\n\nPrompt behavior:\nOn Work and Mux, normal prompt text goes to the selected live PTY.\nOn a Dispatch or Eternal row, normal prompt text accepts or continues that workflow."
}

fn format_projects(data: &Value) -> String {
    let mut out = String::new();
    out.push_str("Profile projects\n\n");
    if let Some(active) = data.get("active").filter(|v| !v.is_null()) {
        out.push_str("Active:\n");
        out.push_str("  ");
        out.push_str(str_field(active, "name").unwrap_or("unnamed"));
        out.push_str("\n  ");
        out.push_str(str_field(active, "root").unwrap_or(""));
        out.push_str("\n\n");
    } else {
        out.push_str("Active: none\n\n");
    }
    out.push_str("Projects:\n");
    let projects = data
        .get("projects")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if projects.is_empty() {
        out.push_str("  none yet\n\n");
    } else {
        for project in projects {
            out.push_str("  ");
            out.push_str(str_field(&project, "name").unwrap_or("unnamed"));
            out.push_str("  ");
            out.push_str(short_id(str_field(&project, "id").unwrap_or("")).as_str());
            out.push('\n');
            out.push_str("    ");
            out.push_str(str_field(&project, "root").unwrap_or(""));
            out.push('\n');
        }
        out.push('\n');
    }
    out
}

fn setting_count() -> usize {
    25
}

fn setting_lines(state: &AgentOsState) -> Vec<Line<'static>> {
    let settings = &state.settings;
    vec![
        setting_line(
            "Project prompt agent",
            option_label(ENGINE_LABELS, settings.default_engine),
        ),
        setting_line("Codex mode", CODEX_MODES[settings.codex_mode].0),
        setting_line("Codex model", CODEX_MODELS[settings.codex_model].0),
        setting_line("Codex effort", CODEX_EFFORTS[settings.codex_effort].0),
        setting_line(
            "Codex alternate screen",
            on_off(settings.codex_alternate_screen),
        ),
        setting_line("Codex account", settings.codex_account_label.clone()),
        setting_line("Advisor mode", on_off(settings.advisor_enabled)),
        setting_line(
            "Executioner permission",
            advisor_permission_label(settings, AdvisorRole::Executioner),
        ),
        setting_line(
            "Executioner model",
            advisor_model_label(settings, AdvisorRole::Executioner),
        ),
        setting_line(
            "Executioner effort",
            advisor_effort_label(settings, AdvisorRole::Executioner),
        ),
        setting_line(
            "Advisor permission",
            advisor_permission_label(settings, AdvisorRole::Advisor),
        ),
        setting_line(
            "Advisor model",
            advisor_model_label(settings, AdvisorRole::Advisor),
        ),
        setting_line(
            "Advisor effort",
            advisor_effort_label(settings, AdvisorRole::Advisor),
        ),
        setting_line("Random tile color", on_off(settings.random_tile_color)),
        setting_line(
            "Default theme",
            option_label(THEMES, settings.default_theme),
        ),
        setting_line(
            "Terminal font size",
            format!("{} pt", settings.terminal_font_size),
        ),
        setting_line("Cursor blink", on_off(settings.cursor_blink)),
        setting_line("Bell mode", option_label(BELL_MODES, settings.bell_mode)),
        setting_line("Grid columns", settings.grid_columns.to_string()),
        setting_line("Code indexing", on_off(settings.code_indexing_enabled)),
        setting_line(
            "Auto-activate selected project",
            on_off(settings.auto_activate_project),
        ),
        setting_line(
            "Follow transcript output",
            on_off(settings.follow_transcript),
        ),
        setting_line("Compact Kanban cards", on_off(settings.compact_board)),
        setting_line("Show done cards", on_off(settings.show_done_cards)),
        setting_line(
            "Events view",
            if settings.human_events {
                "human"
            } else {
                "json"
            },
        ),
    ]
}

fn setting_line(label: impl Into<String>, value: impl Into<String>) -> Line<'static> {
    Line::from(vec![
        Span::styled(label.into(), Style::default().fg(Color::White)),
        Span::raw("  "),
        Span::styled(value.into(), Style::default().fg(Color::Cyan)),
    ])
}

fn option_label(options: &[&str], selected: usize) -> String {
    options
        .get(selected)
        .copied()
        .unwrap_or_else(|| options.first().copied().unwrap_or(""))
        .to_string()
}

fn advisor_permission_label(settings: &UiSettings, role: AdvisorRole) -> String {
    match role {
        AdvisorRole::Executioner => CODEX_MODES[settings.advisor_executioner_codex_mode]
            .0
            .to_string(),
        AdvisorRole::Advisor => CODEX_MODES[settings.advisor_advisor_codex_mode]
            .0
            .to_string(),
    }
}

fn advisor_model_label(settings: &UiSettings, role: AdvisorRole) -> String {
    match role {
        AdvisorRole::Executioner => CODEX_MODELS[settings.advisor_executioner_codex_model]
            .0
            .to_string(),
        AdvisorRole::Advisor => CODEX_MODELS[settings.advisor_advisor_codex_model]
            .0
            .to_string(),
    }
}

fn advisor_effort_label(settings: &UiSettings, role: AdvisorRole) -> String {
    match role {
        AdvisorRole::Executioner => CODEX_EFFORTS[settings.advisor_executioner_codex_effort]
            .0
            .to_string(),
        AdvisorRole::Advisor => CODEX_EFFORTS[settings.advisor_advisor_codex_effort]
            .0
            .to_string(),
    }
}

fn on_off(value: bool) -> &'static str {
    if value {
        "on"
    } else {
        "off"
    }
}

fn move_setting_selection(state: &mut AgentOsState, delta: isize) {
    let len = setting_count();
    let current = state.settings_selected.min(len - 1) as isize;
    state.settings_selected = (current + delta).rem_euclid(len as isize) as usize;
}

fn adjust_setting(state: &mut AgentOsState, delta: isize) {
    match state.settings_selected.min(setting_count() - 1) {
        0 => {
            state.settings.default_engine =
                cycle_index(state.settings.default_engine, DEFAULT_ENGINES.len(), delta);
        }
        1 => {
            state.settings.codex_mode =
                cycle_index(state.settings.codex_mode, CODEX_MODES.len(), delta);
        }
        2 => {
            state.settings.codex_model =
                cycle_index(state.settings.codex_model, CODEX_MODELS.len(), delta);
        }
        3 => {
            state.settings.codex_effort =
                cycle_index(state.settings.codex_effort, CODEX_EFFORTS.len(), delta);
        }
        4 => state.settings.codex_alternate_screen = !state.settings.codex_alternate_screen,
        5 => {}
        6 => {
            state.settings.advisor_enabled = !state.settings.advisor_enabled;
            if state.settings.advisor_enabled {
                initialize_advisor_defaults(&mut state.settings);
            }
        }
        7 => adjust_advisor_permission(&mut state.settings, AdvisorRole::Executioner, delta),
        8 => adjust_advisor_model(&mut state.settings, AdvisorRole::Executioner, delta),
        9 => adjust_advisor_effort(&mut state.settings, AdvisorRole::Executioner, delta),
        10 => adjust_advisor_permission(&mut state.settings, AdvisorRole::Advisor, delta),
        11 => adjust_advisor_model(&mut state.settings, AdvisorRole::Advisor, delta),
        12 => adjust_advisor_effort(&mut state.settings, AdvisorRole::Advisor, delta),
        13 => state.settings.random_tile_color = !state.settings.random_tile_color,
        14 => {
            state.settings.default_theme =
                cycle_index(state.settings.default_theme, THEMES.len(), delta);
        }
        15 => adjust_u8(&mut state.settings.terminal_font_size, delta, 9, 24),
        16 => state.settings.cursor_blink = !state.settings.cursor_blink,
        17 => {
            state.settings.bell_mode =
                cycle_index(state.settings.bell_mode, BELL_MODES.len(), delta)
        }
        18 => adjust_u8(&mut state.settings.grid_columns, delta, 1, 8),
        19 => state.settings.code_indexing_enabled = !state.settings.code_indexing_enabled,
        20 => state.settings.auto_activate_project = !state.settings.auto_activate_project,
        21 => {
            state.settings.follow_transcript = !state.settings.follow_transcript;
            state.follow_output = state.settings.follow_transcript;
        }
        22 => state.settings.compact_board = !state.settings.compact_board,
        23 => state.settings.show_done_cards = !state.settings.show_done_cards,
        24 => state.settings.human_events = !state.settings.human_events,
        _ => {}
    }
    let line = setting_lines(state)
        .get(state.settings_selected.min(setting_count() - 1))
        .map(|line| {
            line.spans
                .iter()
                .map(|span| span.content.as_ref())
                .collect::<String>()
        })
        .unwrap_or_else(|| "Settings updated".to_string());
    state.tui.status = Some(line);
    if let Err(err) = save_settings(state) {
        state.tui.status = Some(format!("Settings changed but not saved: {err}"));
    }
}

fn adjust_advisor_permission(settings: &mut UiSettings, role: AdvisorRole, delta: isize) {
    match role {
        AdvisorRole::Executioner => {
            settings.advisor_executioner_codex_mode = cycle_index(
                settings.advisor_executioner_codex_mode,
                CODEX_MODES.len(),
                delta,
            );
        }
        AdvisorRole::Advisor => {
            settings.advisor_advisor_codex_mode = cycle_index(
                settings.advisor_advisor_codex_mode,
                CODEX_MODES.len(),
                delta,
            );
        }
    }
}

fn adjust_advisor_model(settings: &mut UiSettings, role: AdvisorRole, delta: isize) {
    match role {
        AdvisorRole::Executioner => {
            settings.advisor_executioner_codex_model = cycle_index(
                settings.advisor_executioner_codex_model,
                CODEX_MODELS.len(),
                delta,
            );
        }
        AdvisorRole::Advisor => {
            settings.advisor_advisor_codex_model = cycle_index(
                settings.advisor_advisor_codex_model,
                CODEX_MODELS.len(),
                delta,
            );
        }
    }
}

fn adjust_advisor_effort(settings: &mut UiSettings, role: AdvisorRole, delta: isize) {
    match role {
        AdvisorRole::Executioner => {
            settings.advisor_executioner_codex_effort = cycle_index(
                settings.advisor_executioner_codex_effort,
                CODEX_EFFORTS.len(),
                delta,
            );
        }
        AdvisorRole::Advisor => {
            settings.advisor_advisor_codex_effort = cycle_index(
                settings.advisor_advisor_codex_effort,
                CODEX_EFFORTS.len(),
                delta,
            );
        }
    }
}

fn cycle_index(current: usize, len: usize, delta: isize) -> usize {
    if len == 0 {
        return 0;
    }
    (current.min(len - 1) as isize + delta).rem_euclid(len as isize) as usize
}

fn adjust_u8(value: &mut u8, delta: isize, min: u8, max: u8) {
    let next = (*value as isize + delta).clamp(min as isize, max as isize);
    *value = next as u8;
}

fn header_context(state: &AgentOsState) -> String {
    let active = state.active_project_root.as_deref().unwrap_or("none");
    let live = state
        .tui
        .rows
        .iter()
        .filter(|row| matches!(row.status.as_str(), "running" | "waiting"))
        .count();
    match state.mode {
        Mode::Use => format!(
            "Controls and commands  |  active project: {active}  |  sessions: {}  |  live: {live}",
            state.tui.rows.len()
        ),
        Mode::Projects => format!(
            "active project: {active}  |  projects: {}  |  sessions: {}",
            state.projects.len(),
            state.tui.rows.len()
        ),
        Mode::Settings => format!("active project: {active}  |  live sessions: {live}"),
        _ => format!(
            "active project: {active}  |  sessions: {}  |  live: {live}",
            state.tui.rows.len()
        ),
    }
}

fn prompt_title(engine: &str, text: &str) -> String {
    let trimmed = text.trim();
    let mut title = format!("{engine}: ");
    title.push_str(trimmed.chars().take(72).collect::<String>().as_str());
    if trimmed.chars().count() > 72 {
        title.push_str("...");
    }
    title
}

fn is_done_status(status: &str) -> bool {
    matches!(
        status.to_ascii_lowercase().as_str(),
        "done" | "exited" | "stopped" | "killed" | "failed" | "error"
    )
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
        WorkKind::Tile => "pty",
        WorkKind::Todo => "todo",
        WorkKind::Eternal => "eternal",
        WorkKind::Dispatch => "dispatch",
    }
}

fn short_id(id: &str) -> String {
    if id.len() <= 8 {
        id.to_string()
    } else {
        id[..8].to_string()
    }
}

fn set_mode(state: &mut AgentOsState, mode: Mode) {
    if state.mode != mode {
        state.mode = mode;
        state.scroll = 0;
        state.follow_output = matches!(mode, Mode::Mux);
    }
}

fn shifted_page_mode(code: KeyCode, modifiers: KeyModifiers) -> Option<Mode> {
    match code {
        KeyCode::Char('1') if modifiers.contains(KeyModifiers::SHIFT) => Some(Mode::Work),
        KeyCode::Char('2') if modifiers.contains(KeyModifiers::SHIFT) => Some(Mode::Board),
        KeyCode::Char('3') if modifiers.contains(KeyModifiers::SHIFT) => Some(Mode::Mux),
        KeyCode::Char('4') if modifiers.contains(KeyModifiers::SHIFT) => Some(Mode::Events),
        KeyCode::Char('5') if modifiers.contains(KeyModifiers::SHIFT) => Some(Mode::Use),
        KeyCode::Char('6') if modifiers.contains(KeyModifiers::SHIFT) => Some(Mode::Projects),
        KeyCode::Char('7') if modifiers.contains(KeyModifiers::SHIFT) => Some(Mode::Settings),
        KeyCode::Char('!') => Some(Mode::Work),
        KeyCode::Char('@') => Some(Mode::Board),
        KeyCode::Char('#') => Some(Mode::Mux),
        KeyCode::Char('$') => Some(Mode::Events),
        KeyCode::Char('%') => Some(Mode::Use),
        KeyCode::Char('^') => Some(Mode::Projects),
        KeyCode::Char('&') => Some(Mode::Settings),
        _ => None,
    }
}

fn scroll_by(state: &mut AgentOsState, delta: i16) {
    state.follow_output = false;
    if delta.is_negative() {
        state.scroll = state.scroll.saturating_sub(delta.unsigned_abs());
    } else {
        state.scroll = state.scroll.saturating_add(delta as u16);
    }
}

fn bottom_scroll(text: &str, area: Rect) -> u16 {
    let visible = area.height.saturating_sub(2) as usize;
    let lines = text.lines().count();
    lines.saturating_sub(visible).min(u16::MAX as usize) as u16
}

fn prompt_lines(state: &AgentOsState) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(state.tui.draft.clone())];
    let suggestions = command_suggestions(&state.tui.draft);
    if !suggestions.is_empty() {
        lines.push(Line::from(Span::styled(
            "commands",
            Style::default().fg(Color::DarkGray),
        )));
        for (index, spec) in suggestions.iter().take(4).enumerate() {
            let selected = index == state.suggestion_selected.min(suggestions.len() - 1);
            let style = if selected {
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(Color::DarkGray)
            };
            lines.push(Line::from(vec![
                Span::styled(format!("{:<12}", spec.verb), style),
                Span::styled(
                    format!("{:<20}", spec.args),
                    Style::default().fg(Color::Gray),
                ),
                Span::styled(spec.summary, Style::default().fg(Color::DarkGray)),
            ]));
        }
    }
    lines
}

fn command_palette_visible(state: &AgentOsState) -> bool {
    state.tui.draft.trim_start().starts_with('/')
        && !command_suggestions(&state.tui.draft).is_empty()
}

fn command_suggestions(draft: &str) -> Vec<CommandSpec> {
    let trimmed = draft.trim_start();
    if !trimmed.starts_with('/') {
        return Vec::new();
    }
    let token = trimmed.split_whitespace().next().unwrap_or(trimmed);
    COMMANDS
        .iter()
        .copied()
        .filter(|spec| spec.verb.starts_with(token))
        .collect()
}

fn move_suggestion(state: &mut AgentOsState, delta: isize) {
    let len = command_suggestions(&state.tui.draft).len();
    if len == 0 {
        state.suggestion_selected = 0;
        return;
    }
    let current = state.suggestion_selected.min(len - 1) as isize;
    state.suggestion_selected = (current + delta).rem_euclid(len as isize) as usize;
}

fn clamp_suggestion(state: &mut AgentOsState) {
    let len = command_suggestions(&state.tui.draft).len();
    if len == 0 {
        state.suggestion_selected = 0;
    } else if state.suggestion_selected >= len {
        state.suggestion_selected = len - 1;
    }
}

#[cfg(test)]
mod dispatch_tests {
    use super::*;

    #[test]
    fn parses_dispatch_start_type_and_layout() {
        let args = ["--type", "wave", "--layout", "kanban", "Build", "it"];
        let (execution_type, layout, brief) = parse_dispatch_start_args(&args);
        assert_eq!(execution_type, "wave");
        assert_eq!(layout, "kanban");
        assert_eq!(brief, "Build it");
    }

    #[test]
    fn workflow_rows_include_dispatch_execution_type() {
        let rows = workflow_rows(
            &json!({
                "runs": [{
                    "id": "run-1",
                    "kind": "dispatch",
                    "feature": "Wave feature",
                    "mode": "wave",
                    "layout": "grid",
                    "state": "dispatching",
                    "created_at": "2026-05-20T00:00:00Z"
                }]
            }),
            WorkKind::Dispatch,
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].kind, WorkKind::Dispatch);
        assert_eq!(rows[0].target.as_deref(), Some("run-1"));
        assert!(rows[0].title.contains("WAVE"));
    }
}

fn complete_command(state: &mut AgentOsState) -> bool {
    let draft = state.tui.draft.trim_start();
    if !draft.starts_with('/') {
        return false;
    }
    let suggestions = command_suggestions(&state.tui.draft);
    if suggestions.is_empty() {
        return false;
    }
    let token = draft.split_whitespace().next().unwrap_or(draft);
    let has_rest = draft[token.len()..].trim_start().len() < draft[token.len()..].len()
        && !draft[token.len()..].trim().is_empty();
    if token == "/help" {
        return false;
    }
    if token == suggestions[state.suggestion_selected.min(suggestions.len() - 1)].verb && has_rest {
        return false;
    }
    let spec = suggestions[state.suggestion_selected.min(suggestions.len() - 1)];
    state.tui.draft = if spec.args.is_empty() {
        spec.verb.to_string()
    } else {
        format!("{} ", spec.verb)
    };
    state.suggestion_selected = 0;
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_alias_is_suggested() {
        let verbs = command_suggestions("/projects")
            .into_iter()
            .map(|spec| spec.verb)
            .collect::<Vec<_>>();
        assert_eq!(verbs, vec!["/projects"]);
    }

    #[test]
    fn parses_profile_projects() {
        let data = json!({
            "projects": [
                { "id": "abc123", "name": "App", "root": "/tmp/app" }
            ]
        });
        let projects = parse_projects(&data);
        assert_eq!(
            projects,
            vec![ProjectView {
                id: "abc123".to_string(),
                name: "App".to_string(),
                root: "/tmp/app".to_string(),
            }]
        );
    }

    #[test]
    fn human_events_are_not_raw_json_lines() {
        let data = json!({
            "events": [
                {
                    "id": 1,
                    "kind": "project.selected",
                    "subject_id": "abcdef123456",
                    "message": "active project App",
                    "payload": { "project": { "name": "App", "root": "/tmp/app" } },
                    "created_at": "2026-05-15T12:00:00Z"
                }
            ]
        });
        let text = format_events(&data, true);
        assert!(text.contains("Selected project"));
        assert!(text.contains("active project App"));
        assert!(!text.trim_start().starts_with('{'));
    }

    #[test]
    fn advisor_defaults_copy_current_codex_profile() {
        let mut settings = UiSettings {
            default_engine: 2,
            codex_mode: 1,
            codex_model: 2,
            codex_effort: 3,
            ..UiSettings::default()
        };
        initialize_advisor_defaults(&mut settings);
        assert!(settings.advisor_defaults_initialized);
        assert_eq!(advisor_engine(&settings, AdvisorRole::Executioner), "codex");
        assert_eq!(settings.advisor_executioner_codex_mode, 1);
        assert_eq!(settings.advisor_executioner_codex_model, 2);
        assert_eq!(settings.advisor_executioner_codex_effort, 3);
        assert_eq!(advisor_engine(&settings, AdvisorRole::Advisor), "codex");
    }

    #[test]
    fn advisor_role_flags_use_role_profile() {
        let settings = UiSettings {
            advisor_executioner_codex_model: 0,
            advisor_executioner_codex_effort: 3,
            advisor_advisor_codex_model: 1,
            advisor_advisor_codex_effort: 2,
            ..UiSettings::default()
        };
        let exec_flags = spawn_flags_for_advisor_role(&settings, AdvisorRole::Executioner);
        assert!(exec_flags.contains(&"shell_environment_policy.inherit=all".to_string()));
        assert!(exec_flags.contains(&"model=\"gpt-5.5\"".to_string()));
        assert!(exec_flags.contains(&"model_reasoning_effort=\"high\"".to_string()));

        let advisor_flags = spawn_flags_for_advisor_role(&settings, AdvisorRole::Advisor);
        assert!(advisor_flags.contains(&"model=\"gpt-5.4\"".to_string()));
        assert!(advisor_flags.contains(&"model_reasoning_effort=\"medium\"".to_string()));
    }

    #[test]
    fn advisor_prompts_include_target_and_short_step_rules() {
        let prompt = advisor_prompt("ship auth", "session-123", "[1, 2]");
        assert!(prompt.contains("session-123"));
        assert!(prompt.contains("[1, 2]"));
        assert!(prompt.contains("Prefer under 240 characters"));
        assert!(prompt.contains("Do not edit files"));
    }
}
