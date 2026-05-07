//! tado-kanban — read and mutate a project's general Kanban board.
//!
//! Subcommands
//!   list     [--project <name>]
//!     Print the project's kanban mirror as JSON. Default project is
//!     resolved from $TADO_PROJECT (set by `ProcessSpawner` on every
//!     spawned tile) when --project is omitted.
//!
//!   move <todo-id> <column-key> [--project <name>]
//!     Move a card to the named column. Drops a JSON envelope in
//!     `<project>/.tado/kanban/inbox/` for the running Tado app to
//!     pick up via `KanbanInboxWatcher`. Idempotent — if Tado is not
//!     running, the file sits there until next launch and is then
//!     applied.
//!
//!   add-column --title <text> [--key <slug>] [--project <name>]
//!     Append a new project column. Title is the human label, key is
//!     the stable slug used by `tado-kanban move`. When --key is
//!     omitted a fresh `col-<short>` slug is generated.
//!
//! All commands print JSON to stdout (machine-readable). `--human`
//! pretty-prints; `--toon` compacts.

use clap::{Parser, Subcommand};
use serde_json::json;
use std::path::{Path, PathBuf};
use tado_cli::{print_json, OutputMode};

#[derive(Parser)]
#[command(name = "tado-kanban")]
#[command(about = "List and mutate a Tado project's Kanban board.", long_about = None)]
struct Cli {
    #[arg(long, global = true)]
    human: bool,
    #[arg(long, global = true)]
    toon: bool,

    /// Project name (or substring). Falls back to $TADO_PROJECT.
    #[arg(long, global = true)]
    project: Option<String>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print the project's kanban mirror as JSON.
    List,
    /// Move a card to a column. Card id = the todo's UUID
    /// (`tado-list` shows it). Column key = the kebab-slug stored on
    /// the column row (e.g. "backlog", "doing", "done").
    Move {
        /// Card UUID. The same id `tado-list` shows.
        card_id: String,
        /// Destination column key.
        column_key: String,
    },
    /// Append a new column to the board.
    AddColumn {
        /// Display title (human-readable).
        #[arg(long)]
        title: String,
        /// Stable slug for use with `tado-kanban move`. Auto-generated
        /// when omitted.
        #[arg(long)]
        key: Option<String>,
    },
}

fn main() {
    let cli = Cli::parse();
    let mode = OutputMode::from_flags(cli.human, cli.toon);

    let project_root = match resolve_project_root(cli.project.as_deref()) {
        Ok(root) => root,
        Err(msg) => {
            eprintln!("error [no_project]: {}", msg);
            std::process::exit(1);
        }
    };

    match cli.command {
        Command::List => list(&project_root, mode),
        Command::Move { card_id, column_key } => {
            move_card(&project_root, &card_id, &column_key, mode);
        }
        Command::AddColumn { title, key } => {
            add_column(&project_root, &title, key.as_deref(), mode);
        }
    }
}

fn list(project_root: &Path, mode: OutputMode) {
    match tado_cli::disk::read_kanban_state(project_root) {
        Some(state) => {
            let payload = json!({
                "generation": state.generation,
                "project": {
                    "id": state.project.id,
                    "name": state.project.name,
                    "root": state.project.root,
                },
                "columns": state.columns.iter().map(|c| json!({
                    "id": c.id,
                    "columnKey": c.column_key,
                    "title": c.title,
                    "orderIndex": c.order_index,
                })).collect::<Vec<_>>(),
                "cards": state.cards.iter().map(|c| json!({
                    "id": c.id,
                    "text": c.text,
                    "columnKey": c.column_key,
                    "orderIndex": c.order_index,
                    "status": c.status,
                    "agent": c.agent,
                    "createdAt": c.created_at,
                })).collect::<Vec<_>>(),
            });
            print_json(&payload, mode);
        }
        None => {
            // No mirror yet — emit an empty shell so callers don't
            // have to special-case the "first visit" state.
            print_json(
                &json!({
                    "generation": 0,
                    "columns": [],
                    "cards": [],
                    "note": "Kanban not yet initialized for this project. Open the Kanban view in Tado to seed defaults.",
                }),
                mode,
            );
        }
    }
}

fn move_card(project_root: &Path, card_id: &str, column_key: &str, mode: OutputMode) {
    let envelope = json!({
        "kind": "move-card",
        "cardID": card_id,
        "columnKey": column_key,
        "sender": std::env::var("TADO_AGENT").ok(),
    });
    let result = drop_inbox_file(project_root, "move", &envelope);
    print_inbox_result(result, mode, "moved");
}

fn add_column(
    project_root: &Path,
    title: &str,
    key: Option<&str>,
    mode: OutputMode,
) {
    let envelope = json!({
        "kind": "add-column",
        "title": title,
        "columnKey": key,
        "sender": std::env::var("TADO_AGENT").ok(),
    });
    let result = drop_inbox_file(project_root, "add-column", &envelope);
    print_inbox_result(result, mode, "queued");
}

fn drop_inbox_file(
    project_root: &Path,
    prefix: &str,
    envelope: &serde_json::Value,
) -> Result<PathBuf, String> {
    let dir = tado_cli::disk::kanban_inbox_dir(project_root);
    if let Err(e) = std::fs::create_dir_all(&dir) {
        return Err(format!(
            "failed to create inbox dir {}: {}",
            dir.display(),
            e
        ));
    }
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let filename = format!("{}-{}-{}.json", prefix, nanos, uuid::Uuid::new_v4());
    let path = dir.join(filename);
    let raw = match serde_json::to_vec_pretty(envelope) {
        Ok(b) => b,
        Err(e) => return Err(format!("encode envelope: {}", e)),
    };
    if let Err(e) = std::fs::write(&path, &raw) {
        return Err(format!("write {}: {}", path.display(), e));
    }
    Ok(path)
}

fn print_inbox_result(
    result: Result<PathBuf, String>,
    mode: OutputMode,
    verb: &str,
) {
    match result {
        Ok(path) => {
            print_json(
                &json!({
                    "ok": true,
                    "verb": verb,
                    "envelope": path.display().to_string(),
                    "note": "Tado app picks this up within ~200ms when running. Persists on disk if not.",
                }),
                mode,
            );
        }
        Err(msg) => {
            eprintln!("error [inbox]: {}", msg);
            std::process::exit(1);
        }
    }
}

fn resolve_project_root(arg: Option<&str>) -> Result<PathBuf, String> {
    let name = arg
        .map(|s| s.to_string())
        .or_else(|| std::env::var("TADO_PROJECT").ok())
        .ok_or_else(|| {
            "no project: pass --project <name> or set $TADO_PROJECT".to_string()
        })?;
    match tado_cli::disk::resolve_project(&name) {
        Some(entry) => Ok(PathBuf::from(entry.root_path)),
        None => Err(format!("no project named '{}'", name)),
    }
}
