//! Project-tree walker. Honors `.gitignore` + `.ignore` + a hardcoded
//! denylist for vendor/build directories and oversized/binary files.
//!
//! Returns a flat `Vec<WalkedFile>` rather than a streaming iterator
//! so the indexer can show "X files total" up front for the progress
//! bar; in practice this list is bounded (we cap at 25 000 files per
//! project to keep memory predictable).

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use ignore::WalkBuilder;

use crate::code::language::Language;

/// Directories we never descend into, regardless of `.gitignore`.
/// These are the conventional `target/` / vendored-deps style names
/// that aren't worth indexing even if a project forgets to gitignore
/// them.
pub const HARD_SKIP_DIRS: &[&str] = &[
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "target",
    ".build",
    ".swiftpm",
    "DerivedData",
    "Pods",
    "Carthage",
    ".next",
    "dist",
    "build",
    ".venv",
    "venv",
    "__pycache__",
    ".gradle",
    ".idea",
    ".vscode",
    "vendor",
];

/// Files we never index even if their extension matches a language —
/// these are typically generated, minified, or otherwise not worth
/// embedding.
pub const HARD_SKIP_FILE_GLOBS: &[&str] = &[
    "*.lock",
    "*.min.js",
    "*.min.css",
    "*.map",
    "package-lock.json",
    "Cargo.lock",
    "yarn.lock",
    "pnpm-lock.yaml",
];

/// Skip files larger than this on disk. Generated bundles, fixtures,
/// and minified blobs blow well past this; legit source files live
/// well under it. Configurable later via per-project
/// `.tado/code_indexing.json`.
pub const MAX_FILE_BYTES: u64 = 1024 * 1024;
pub const MAX_FILE_LINES: usize = 10_000;

/// Hard cap on the total number of files we'll index per project.
/// Keeps memory predictable and gives users a clear failure mode
/// (the result reports `truncated: true`) rather than silently
/// hanging on a massive monorepo.
pub const MAX_FILES_PER_PROJECT: usize = 25_000;

#[derive(Debug, Clone)]
pub struct WalkedFile {
    pub abs_path: PathBuf,
    pub repo_path: String,
    pub language: Language,
    pub byte_size: u64,
}

#[derive(Debug, Default)]
pub struct WalkResult {
    pub files: Vec<WalkedFile>,
    pub skipped_binary: usize,
    pub skipped_size: usize,
    pub skipped_extension: usize,
    pub truncated: bool,
}

/// Walk `root`, returning every file we want to chunk + embed.
pub fn walk_project(root: &Path) -> WalkResult {
    let mut result = WalkResult::default();
    if !root.is_dir() {
        return result;
    }

    let mut builder = WalkBuilder::new(root);
    builder
        .hidden(false) // we want .github / .claude / etc to surface
        .ignore(true)
        .git_ignore(true)
        .git_exclude(true)
        .git_global(true)
        .require_git(false)
        .parents(true)
        .filter_entry(|entry| {
            // Stop descent into hardcoded denylist directories. The
            // `ignore` crate already filters via .gitignore; this is
            // belt-and-suspenders for projects that forget.
            if entry.file_type().map(|ft| ft.is_dir()).unwrap_or(false) {
                if let Some(name) = entry.file_name().to_str() {
                    if HARD_SKIP_DIRS.contains(&name) {
                        return false;
                    }
                }
            }
            true
        });

    // Honor `.domeignore` exactly like `.gitignore`. Project-local
    // overrides without polluting git history.
    builder.add_custom_ignore_filename(".domeignore");

    for entry in builder.build().flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        if matches_glob_skip(path) {
            continue;
        }
        let Some(language) = Language::from_path(path) else {
            result.skipped_extension += 1;
            continue;
        };
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if meta.len() > MAX_FILE_BYTES {
            result.skipped_size += 1;
            continue;
        }
        if is_binary(path) {
            result.skipped_binary += 1;
            continue;
        }
        let Ok(repo_path) = path.strip_prefix(root) else {
            continue;
        };
        let repo_path = repo_path.to_string_lossy().replace('\\', "/");

        result.files.push(WalkedFile {
            abs_path: path.to_path_buf(),
            repo_path,
            language,
            byte_size: meta.len(),
        });

        if result.files.len() >= MAX_FILES_PER_PROJECT {
            result.truncated = true;
            break;
        }
    }

    result
}

fn matches_glob_skip(path: &Path) -> bool {
    let name = match path.file_name().and_then(|n| n.to_str()) {
        Some(n) => n,
        None => return false,
    };
    for pattern in HARD_SKIP_FILE_GLOBS {
        if glob_match(pattern, name) {
            return true;
        }
    }
    false
}

/// Minimal glob match for our small pattern set: supports `*` and
/// literal text. We don't need full glob semantics here.
fn glob_match(pattern: &str, name: &str) -> bool {
    if pattern == name {
        return true;
    }
    if let Some(rest) = pattern.strip_prefix('*') {
        return name.ends_with(rest);
    }
    if let Some(rest) = pattern.strip_suffix('*') {
        return name.starts_with(rest);
    }
    false
}

/// Treat a file as binary when the first 4 KB contain a NUL byte or
/// >30% non-text characters. This is the same heuristic ripgrep uses.
fn is_binary(path: &Path) -> bool {
    let Ok(mut f) = fs::File::open(path) else {
        return false;
    };
    let mut buf = [0u8; 4096];
    let n = match f.read(&mut buf) {
        Ok(n) => n,
        Err(_) => return false,
    };
    let slice = &buf[..n];
    if slice.contains(&0) {
        return true;
    }
    let nontext = slice
        .iter()
        .filter(|&&b| !(b == b'\t' || b == b'\n' || b == b'\r' || (0x20..0x7f).contains(&b) || b >= 0x80))
        .count();
    nontext * 10 > slice.len() * 3
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn walk_finds_source_files_skips_target() {
        let tmp = tempdir();
        fs::write(tmp.join("main.rs"), "fn main() {}\n").unwrap();
        fs::create_dir_all(tmp.join("target/release")).unwrap();
        fs::write(tmp.join("target/release/junk.rs"), "junk\n").unwrap();
        fs::create_dir_all(tmp.join("src")).unwrap();
        fs::write(tmp.join("src/lib.rs"), "pub fn ok() {}\n").unwrap();

        let result = walk_project(&tmp);
        assert_eq!(result.files.len(), 2);
        let paths: Vec<_> = result.files.iter().map(|f| f.repo_path.clone()).collect();
        assert!(paths.contains(&"main.rs".to_string()));
        assert!(paths.contains(&"src/lib.rs".to_string()));
        assert!(!paths.iter().any(|p| p.contains("target")));
    }

    #[test]
    fn walk_skips_oversized_file() {
        let tmp = tempdir();
        let huge = "x".repeat(MAX_FILE_BYTES as usize + 1024);
        fs::write(tmp.join("huge.rs"), &huge).unwrap();
        fs::write(tmp.join("ok.rs"), "fn ok() {}\n").unwrap();
        let result = walk_project(&tmp);
        assert_eq!(result.skipped_size, 1);
        assert_eq!(result.files.len(), 1);
    }

    #[test]
    fn walk_skips_binary() {
        let tmp = tempdir();
        let mut bin = vec![0u8; 256];
        bin[100] = 0; // NUL byte
        fs::write(tmp.join("binary.c"), &bin).unwrap();
        fs::write(tmp.join("text.c"), "int main(){return 0;}\n").unwrap();
        let result = walk_project(&tmp);
        assert_eq!(result.skipped_binary, 1);
        assert_eq!(result.files.len(), 1);
    }

    #[test]
    fn walk_honors_gitignore() {
        let tmp = tempdir();
        fs::write(tmp.join(".gitignore"), "secret/\n").unwrap();
        fs::create_dir_all(tmp.join("secret")).unwrap();
        fs::write(tmp.join("secret/key.rs"), "fn key() {}\n").unwrap();
        fs::write(tmp.join("public.rs"), "fn pub_() {}\n").unwrap();
        let result = walk_project(&tmp);
        assert_eq!(result.files.len(), 1);
        assert_eq!(result.files[0].repo_path, "public.rs");
    }

    fn tempdir() -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("tado-walker-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
