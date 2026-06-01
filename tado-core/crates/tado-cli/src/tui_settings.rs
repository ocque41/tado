use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdvisorRole {
    Executioner,
    Advisor,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct UiSettings {
    pub default_engine: usize,
    pub codex_mode: usize,
    pub codex_model: usize,
    pub codex_effort: usize,
    pub codex_alternate_screen: bool,
    pub codex_account_label: String,
    pub advisor_enabled: bool,
    pub advisor_defaults_initialized: bool,
    pub advisor_executioner_engine: usize,
    pub advisor_executioner_codex_mode: usize,
    pub advisor_executioner_codex_model: usize,
    pub advisor_executioner_codex_effort: usize,
    pub advisor_advisor_engine: usize,
    pub advisor_advisor_codex_mode: usize,
    pub advisor_advisor_codex_model: usize,
    pub advisor_advisor_codex_effort: usize,
    pub random_tile_color: bool,
    pub default_theme: usize,
    pub terminal_font_size: u8,
    pub cursor_blink: bool,
    pub bell_mode: usize,
    pub grid_columns: u8,
    pub code_indexing_enabled: bool,
    pub auto_activate_project: bool,
    pub follow_transcript: bool,
    pub compact_board: bool,
    pub show_done_cards: bool,
    pub human_events: bool,
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

pub const DEFAULT_ENGINES: &[&str] = &["shell", "codex"];
pub const ENGINE_LABELS: &[&str] = &["Shell", "Codex"];
pub const CODEX_MODES: &[(&str, &[&str])] = &[
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
pub const CODEX_MODELS: &[(&str, &str)] = &[
    ("GPT-5.5", "gpt-5.5"),
    ("GPT-5.4", "gpt-5.4"),
    ("GPT-5.4-Mini", "gpt-5.4-mini"),
    ("GPT-5.3-Codex", "gpt-5.3-codex"),
    ("GPT-5.2", "gpt-5.2"),
];
pub const CODEX_EFFORTS: &[(&str, Option<&str>)] = &[
    ("Auto", None),
    ("Low", Some("low")),
    ("Medium", Some("medium")),
    ("High", Some("high")),
    ("Extra high", Some("xhigh")),
];
pub const THEMES: &[&str] = &[
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
pub const BELL_MODES: &[&str] = &["Off", "Audible", "Visual", "Audible + visual"];

pub fn clamp_settings(settings: &mut UiSettings) {
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

pub fn spawn_flags_for_engine(settings: &UiSettings, engine: &str) -> Vec<String> {
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

pub fn spawn_env_for_engine(_settings: &UiSettings, _engine: &str) -> Vec<(String, String)> {
    Vec::new()
}

pub fn advisor_engine(_settings: &UiSettings, _role: AdvisorRole) -> &'static str {
    "codex"
}

pub fn spawn_flags_for_advisor_role(settings: &UiSettings, role: AdvisorRole) -> Vec<String> {
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

pub fn initialize_advisor_defaults(settings: &mut UiSettings) {
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

pub fn advisor_permission_label(settings: &UiSettings, role: AdvisorRole) -> String {
    match role {
        AdvisorRole::Executioner => CODEX_MODES[settings.advisor_executioner_codex_mode]
            .0
            .to_string(),
        AdvisorRole::Advisor => CODEX_MODES[settings.advisor_advisor_codex_mode]
            .0
            .to_string(),
    }
}

pub fn advisor_model_label(settings: &UiSettings, role: AdvisorRole) -> String {
    match role {
        AdvisorRole::Executioner => CODEX_MODELS[settings.advisor_executioner_codex_model]
            .0
            .to_string(),
        AdvisorRole::Advisor => CODEX_MODELS[settings.advisor_advisor_codex_model]
            .0
            .to_string(),
    }
}

pub fn advisor_effort_label(settings: &UiSettings, role: AdvisorRole) -> String {
    match role {
        AdvisorRole::Executioner => CODEX_EFFORTS[settings.advisor_executioner_codex_effort]
            .0
            .to_string(),
        AdvisorRole::Advisor => CODEX_EFFORTS[settings.advisor_advisor_codex_effort]
            .0
            .to_string(),
    }
}

pub fn adjust_advisor_permission(settings: &mut UiSettings, role: AdvisorRole, delta: isize) {
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

pub fn adjust_advisor_model(settings: &mut UiSettings, role: AdvisorRole, delta: isize) {
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

pub fn adjust_advisor_effort(settings: &mut UiSettings, role: AdvisorRole, delta: isize) {
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

pub fn cycle_index(current: usize, len: usize, delta: isize) -> usize {
    if len == 0 {
        return 0;
    }
    (current.min(len - 1) as isize + delta).rem_euclid(len as isize) as usize
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
