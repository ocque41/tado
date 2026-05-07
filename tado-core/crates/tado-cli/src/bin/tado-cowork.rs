//! tado-cowork — fire `claude://cowork/new?q=…&folder=…` so the
//! Tado app's `ProcessSpawner` can launch a Cowork task against
//! the bundled Tado-Cowork plugin.
//!
//! Cowork has no headless CLI surface; it lives inside the Claude
//! Desktop app (`com.anthropic.claudefordesktop`). Anthropic
//! exposes a documented URL scheme for opening the app into a new
//! Cowork task with a pre-filled prompt + attached folders + files.
//! That URL scheme is what this binary builds and shells out to
//! `open(1)` against — replacing what would otherwise have to be
//! an AppleScript / Accessibility-API bridge.
//!
//! Usage (driven by `ProcessSpawner.command(engine: .cowork, …)`):
//!
//!     tado-cowork --prompt "<text>" --folder /abs/path \
//!                 --run-id <uuid> [--file /abs/file]*
//!
//! Exit codes:
//!   0   — `open(1)` returned 0 (URL scheme handler accepted)
//!   1   — Claude Desktop is not installed at any known path
//!   2   — invalid args (missing --prompt or --folder)
//!   3   — `open(1)` returned non-zero
//!
//! On success the CLI also writes a one-line status report to
//! stdout: the Cowork run-id Tado generated and a hint at the
//! file Cowork is expected to write its result to (the convention
//! the bundled plugin's `cowork-tado-tools` skill teaches Cowork).
//! `ProcessSpawner` reads that line into the tile so the user sees
//! a clear "Cowork launched" status before the output poller
//! takes over.

use std::path::Path;
use std::process::{Command, exit};

#[derive(Debug)]
struct Args {
    prompt: String,
    folder: String,
    run_id: String,
    files: Vec<String>,
}

fn parse_args() -> Result<Args, String> {
    let mut prompt: Option<String> = None;
    let mut folder: Option<String> = None;
    let mut run_id: Option<String> = None;
    let mut files: Vec<String> = Vec::new();
    let argv: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < argv.len() {
        let a = &argv[i];
        match a.as_str() {
            "--prompt" => {
                i += 1;
                if i >= argv.len() { return Err("--prompt requires a value".into()); }
                prompt = Some(argv[i].clone());
            }
            "--folder" => {
                i += 1;
                if i >= argv.len() { return Err("--folder requires a value".into()); }
                folder = Some(argv[i].clone());
            }
            "--run-id" => {
                i += 1;
                if i >= argv.len() { return Err("--run-id requires a value".into()); }
                run_id = Some(argv[i].clone());
            }
            "--file" => {
                i += 1;
                if i >= argv.len() { return Err("--file requires a value".into()); }
                files.push(argv[i].clone());
            }
            "--help" | "-h" => {
                print_usage();
                exit(0);
            }
            other => {
                return Err(format!("unknown argument: {other}"));
            }
        }
        i += 1;
    }
    let prompt = prompt.ok_or("missing required --prompt")?;
    let folder = folder.ok_or("missing required --folder")?;
    let run_id = run_id.unwrap_or_else(|| {
        // Lightweight UUID-like fallback: ts + nanos. Avoids the
        // uuid crate dependency on this hot-path binary.
        format!(
            "tado-cowork-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        )
    });
    Ok(Args { prompt, folder, run_id, files })
}

fn print_usage() {
    eprintln!("tado-cowork — fire claude://cowork/new for the Tado app's ProcessSpawner");
    eprintln!();
    eprintln!("Usage:");
    eprintln!("  tado-cowork --prompt <text> --folder <abs-path> [--run-id <uuid>] [--file <abs-path>]*");
}

/// RFC 3986 percent-encoding for query components. We can't use a
/// crate (clean dep tree on this binary), so implement the spec
/// directly: percent-encode anything that isn't unreserved + a
/// small set of safe sub-delims. Spaces become `%20` (not `+`)
/// because the `claude://` URL handler interprets `+` literally
/// in some macOS versions.
fn encode_query(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9'
            | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char);
            }
            _ => {
                out.push_str(&format!("%{:02X}", byte));
            }
        }
    }
    out
}

/// Build the `claude://cowork/new?…` URL. Anthropic's documented
/// keys: `q` (prompt), `folder` (repeatable), `file` (repeatable).
/// We always include exactly one `folder` (the project root the
/// caller passed in) and zero-or-more `file` entries. The run-id
/// rides as a leading `[Tado run <id>]` sentinel inside the prompt
/// so Cowork can surface it back into its task list and the bundled
/// `cowork-tado-tools` skill knows what filename to write its
/// result markdown to.
fn build_url(args: &Args) -> String {
    let preamble = format!(
        "[Tado run {}]\n\nWhen you've finished this task, write your result \
         to `{}/.tado/cowork/{}.md` (the bundled `cowork-tado-tools` skill \
         describes the format). Tado polls that file and renders it back \
         into the canvas tile.\n\n---\n\n",
        args.run_id, args.folder, args.run_id
    );
    let q = encode_query(&format!("{}{}", preamble, args.prompt));
    let folder = encode_query(&args.folder);
    let mut url = format!("claude://cowork/new?q={q}&folder={folder}");
    for f in &args.files {
        url.push_str("&file=");
        url.push_str(&encode_query(f));
    }
    url
}

fn claude_desktop_installed() -> bool {
    // Two-pronged check: the canonical install location, and an
    // mdfind probe by bundle id for Homebrew Cask / non-Applications
    // installs. The CLI doesn't need to LAUNCH the app — `open(1)`
    // does that — but we want a clear error message if the user
    // doesn't have Claude Desktop installed at all.
    if Path::new("/Applications/Claude.app").exists() { return true; }
    let out = Command::new("mdfind")
        .args(["kMDItemCFBundleIdentifier", "==", "com.anthropic.claudefordesktop"])
        .output();
    match out {
        Ok(o) if o.status.success() && !o.stdout.is_empty() => true,
        _ => false,
    }
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("tado-cowork: {e}");
            print_usage();
            exit(2);
        }
    };

    if !claude_desktop_installed() {
        eprintln!(
            "tado-cowork: Claude Desktop is not installed. \
             Download it from https://claude.com/download — Cowork lives \
             inside the Desktop app (com.anthropic.claudefordesktop)."
        );
        exit(1);
    }

    let url = build_url(&args);

    // Write the status preamble to the tile BEFORE shelling open.
    // ProcessSpawner reads this line so the tile shows feedback
    // even if the URL handler is slow on cold-launch (3–8 s on
    // some machines while Claude Desktop wakes from suspend).
    println!(
        "Cowork task launched in Claude Desktop.\n\
         Run id: {}\n\
         Result file: {}/.tado/cowork/{}.md\n\
         (Tado polls this file and renders the result back into this tile.)",
        args.run_id, args.folder, args.run_id
    );

    let status = Command::new("/usr/bin/open")
        .arg(&url)
        .status();
    match status {
        Ok(s) if s.success() => exit(0),
        Ok(s) => {
            eprintln!("tado-cowork: open(1) failed with status {:?}", s);
            exit(3);
        }
        Err(e) => {
            eprintln!("tado-cowork: failed to spawn open(1): {e}");
            exit(3);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_unreserved() {
        assert_eq!(encode_query("abc-_.~"), "abc-_.~");
    }

    #[test]
    fn encodes_space() {
        assert_eq!(encode_query("a b"), "a%20b");
    }

    #[test]
    fn encodes_query_metacharacters() {
        assert_eq!(encode_query("a&b=c?d"), "a%26b%3Dc%3Fd");
    }

    #[test]
    fn builds_url_with_folder_and_file() {
        let args = Args {
            prompt: "hello".into(),
            folder: "/tmp".into(),
            run_id: "abc123".into(),
            files: vec!["/tmp/x.md".into()],
        };
        let url = build_url(&args);
        assert!(url.starts_with("claude://cowork/new?q="));
        assert!(url.contains("&folder=%2Ftmp"));
        assert!(url.contains("&file=%2Ftmp%2Fx.md"));
        // The run-id rides in the encoded preamble.
        assert!(url.contains("abc123"));
    }
}
