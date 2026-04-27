//! Source file → chunk list.
//!
//! Two strategies behind a `Chunker` trait:
//!
//! - [`TreeSitterChunker`] — AST-aware. Walks the parse tree, keeps
//!   nodes matching `Language::chunk_node_kinds()` as their own chunks
//!   (functions, classes, impls, etc.). Falls back to line-window
//!   chunks for code outside any matched node (top-level statements,
//!   imports, comments).
//! - [`LineWindowChunker`] — overlapping line windows. Used for any
//!   language without tree-sitter coverage and as the fallback when
//!   AST parsing fails.
//!
//! ## Why the line-window fallback exists inside TreeSitterChunker
//!
//! Real codebases have meaningful content *outside* function bodies:
//! the top-of-file imports + module-level constants in Rust, decorator
//! pragmas in Python, top-level type aliases in TS. If we only kept
//! AST nodes we'd silently drop those. Instead we also chunk the
//! "leftover" line ranges in fixed windows so retrieval can find an
//! `import { foo } from "bar"` clause when an agent asks "where is bar
//! imported".

use crate::code::language::Language;

/// Target chunk size in lines for the line-window strategy.
const WINDOW_LINES: usize = 40;
/// Overlap between consecutive windows so a relevant token at a window
/// boundary still gets caught. 5 lines ≈ ~12% overlap.
const WINDOW_OVERLAP: usize = 5;

/// Hard cap on chunk byte length even from AST nodes. A 50 KB function
/// embedded as one chunk gets a single mediocre vector; better to
/// split it into sub-windows of 800 lines max.
const MAX_CHUNK_LINES: usize = 800;
/// Drop chunks shorter than this — they're typically braces / single
/// imports / blank line groups that add noise without retrieval lift.
const MIN_CHUNK_BYTES: usize = 16;

#[derive(Debug, Clone)]
pub struct CodeChunk {
    pub text: String,
    pub language: Language,
    pub node_kind: Option<String>,
    pub qualified_name: Option<String>,
    pub start_line: u32,
    pub end_line: u32,
    pub byte_start: u32,
    pub byte_end: u32,
}

pub trait Chunker {
    fn chunk(&self, source: &str, language: Language) -> Vec<CodeChunk>;
}

/// Default chunker: tree-sitter for languages with grammars, line-window
/// for everything else.
pub fn default_chunker() -> Box<dyn Chunker + Send + Sync> {
    Box::new(TreeSitterChunker::new())
}

#[derive(Default)]
pub struct TreeSitterChunker;

impl TreeSitterChunker {
    pub fn new() -> Self {
        Self
    }
}

impl Chunker for TreeSitterChunker {
    fn chunk(&self, source: &str, language: Language) -> Vec<CodeChunk> {
        let Some(ts_lang) = language.ts_language() else {
            return LineWindowChunker.chunk(source, language);
        };

        let mut parser = tree_sitter::Parser::new();
        if parser.set_language(&ts_lang).is_err() {
            return LineWindowChunker.chunk(source, language);
        }
        let Some(tree) = parser.parse(source, None) else {
            return LineWindowChunker.chunk(source, language);
        };

        let kinds = language.chunk_node_kinds();
        if kinds.is_empty() {
            return LineWindowChunker.chunk(source, language);
        }

        let bytes = source.as_bytes();
        let mut chunks: Vec<CodeChunk> = Vec::new();
        let mut covered: Vec<(usize, usize)> = Vec::new();
        let root = tree.root_node();
        let mut visit: Vec<tree_sitter::Node> = vec![root];
        while let Some(node) = visit.pop() {
            let kind = node.kind();
            if kinds.contains(&kind) {
                let s = node.start_byte();
                let e = node.end_byte();
                if e > s && e <= bytes.len() {
                    let snippet = match std::str::from_utf8(&bytes[s..e]) {
                        Ok(s) => s,
                        Err(_) => continue,
                    };
                    let qualified = node_qualified_name(&node, source);
                    push_node_chunks(
                        &mut chunks,
                        snippet,
                        s as u32,
                        node.start_position().row as u32,
                        language,
                        Some(kind.to_string()),
                        qualified,
                    );
                    covered.push((s, e));
                    continue; // don't recurse into a chunked node
                }
            }
            // Recurse into children.
            for i in 0..node.child_count() {
                if let Some(child) = node.child(i as u32) {
                    visit.push(child);
                }
            }
        }

        // Fill gaps between AST chunks with line-window chunks so we
        // don't silently drop top-of-file imports / module-level
        // constants / the regions between functions.
        covered.sort_by_key(|(s, _)| *s);
        let mut gaps: Vec<(usize, usize)> = Vec::new();
        let mut prev_end = 0usize;
        for (s, e) in &covered {
            if *s > prev_end {
                gaps.push((prev_end, *s));
            }
            prev_end = (*e).max(prev_end);
        }
        if prev_end < bytes.len() {
            gaps.push((prev_end, bytes.len()));
        }
        for (s, e) in gaps {
            let Ok(slice) = std::str::from_utf8(&bytes[s..e]) else {
                continue;
            };
            if slice.trim().len() < MIN_CHUNK_BYTES {
                continue;
            }
            let start_line = byte_to_line(source, s) as u32;
            push_node_chunks(
                &mut chunks,
                slice,
                s as u32,
                start_line,
                language,
                None,
                None,
            );
        }

        // Sort by byte_start so chunk_index is in reading order.
        chunks.sort_by_key(|c| c.byte_start);
        chunks
            .into_iter()
            .filter(|c| c.text.trim().len() >= MIN_CHUNK_BYTES)
            .collect()
    }
}

#[derive(Default)]
pub struct LineWindowChunker;

impl Chunker for LineWindowChunker {
    fn chunk(&self, source: &str, language: Language) -> Vec<CodeChunk> {
        if source.trim().is_empty() {
            return Vec::new();
        }
        let line_offsets = build_line_offsets(source);
        let total_lines = line_offsets.len();
        let mut chunks = Vec::new();
        let mut start_line = 0usize;
        while start_line < total_lines {
            let end_line = (start_line + WINDOW_LINES).min(total_lines);
            let byte_start = line_offsets[start_line];
            let byte_end = if end_line >= total_lines {
                source.len()
            } else {
                line_offsets[end_line]
            };
            if let Some(text) = source.get(byte_start..byte_end) {
                if text.trim().len() >= MIN_CHUNK_BYTES {
                    chunks.push(CodeChunk {
                        text: text.to_string(),
                        language,
                        node_kind: None,
                        qualified_name: None,
                        start_line: start_line as u32,
                        end_line: (end_line.saturating_sub(1)) as u32,
                        byte_start: byte_start as u32,
                        byte_end: byte_end as u32,
                    });
                }
            }
            if end_line >= total_lines {
                break;
            }
            start_line = end_line.saturating_sub(WINDOW_OVERLAP);
            if start_line == 0 {
                start_line = end_line; // avoid infinite loop on tiny windows
            }
        }
        chunks
    }
}

/// If an AST node yields a chunk longer than `MAX_CHUNK_LINES`, split
/// it into sub-windows so each chunk fits the embedder's context cap
/// (~512 tokens / ~40 lines of typical code).
fn push_node_chunks(
    out: &mut Vec<CodeChunk>,
    snippet: &str,
    abs_byte_offset: u32,
    abs_line_offset: u32,
    language: Language,
    node_kind: Option<String>,
    qualified_name: Option<String>,
) {
    let line_offsets = build_line_offsets(snippet);
    let total_lines = line_offsets.len();
    if total_lines <= MAX_CHUNK_LINES {
        if snippet.trim().len() < MIN_CHUNK_BYTES {
            return;
        }
        out.push(CodeChunk {
            text: snippet.to_string(),
            language,
            node_kind,
            qualified_name,
            start_line: abs_line_offset,
            end_line: abs_line_offset + (total_lines.saturating_sub(1) as u32),
            byte_start: abs_byte_offset,
            byte_end: abs_byte_offset + snippet.len() as u32,
        });
        return;
    }
    // Chunk too big — split with line-window strategy preserving the
    // node metadata.
    let mut start_line = 0usize;
    while start_line < total_lines {
        let end_line = (start_line + WINDOW_LINES).min(total_lines);
        let byte_start = line_offsets[start_line];
        let byte_end = if end_line >= total_lines {
            snippet.len()
        } else {
            line_offsets[end_line]
        };
        if let Some(text) = snippet.get(byte_start..byte_end) {
            if text.trim().len() >= MIN_CHUNK_BYTES {
                out.push(CodeChunk {
                    text: text.to_string(),
                    language,
                    node_kind: node_kind.clone(),
                    qualified_name: qualified_name.clone(),
                    start_line: abs_line_offset + start_line as u32,
                    end_line: abs_line_offset + (end_line.saturating_sub(1) as u32),
                    byte_start: abs_byte_offset + byte_start as u32,
                    byte_end: abs_byte_offset + byte_end as u32,
                });
            }
        }
        if end_line >= total_lines {
            break;
        }
        start_line = end_line.saturating_sub(WINDOW_OVERLAP);
        if start_line == 0 {
            start_line = end_line;
        }
    }
}

/// Map byte offset → 0-based line index. Used when computing the
/// starting line of gap-window chunks against the original source.
fn byte_to_line(source: &str, byte: usize) -> usize {
    source[..byte.min(source.len())].bytes().filter(|b| *b == b'\n').count()
}

fn build_line_offsets(source: &str) -> Vec<usize> {
    let mut offsets = Vec::with_capacity(64);
    offsets.push(0);
    for (i, b) in source.bytes().enumerate() {
        if b == b'\n' && i + 1 < source.len() {
            offsets.push(i + 1);
        }
    }
    offsets
}

/// Try to extract a `qualified_name` from an AST node — the function
/// or class name. Best-effort; falls back to None if the grammar
/// doesn't expose a `name` field.
fn node_qualified_name(node: &tree_sitter::Node, source: &str) -> Option<String> {
    let bytes = source.as_bytes();
    if let Some(name_node) = node.child_by_field_name("name") {
        let s = name_node.start_byte();
        let e = name_node.end_byte();
        if e <= bytes.len() {
            if let Ok(name) = std::str::from_utf8(&bytes[s..e]) {
                return Some(name.to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_window_splits_long_input() {
        let mut source = String::new();
        for i in 0..120 {
            source.push_str(&format!("let x_{i} = {i};\n"));
        }
        let chunks = LineWindowChunker.chunk(&source, Language::Rust);
        assert!(chunks.len() >= 3, "got {} chunks", chunks.len());
        // Adjacent chunks should overlap in line ranges.
        let mut prev_end = 0u32;
        for c in &chunks {
            assert!(c.start_line <= prev_end + WINDOW_LINES as u32);
            prev_end = c.end_line;
        }
    }

    #[test]
    fn line_window_skips_blank() {
        let chunks = LineWindowChunker.chunk("   \n\n", Language::Rust);
        assert!(chunks.is_empty());
    }

    #[test]
    fn tree_sitter_extracts_rust_functions() {
        let source = r#"
use std::path::Path;

pub fn alpha(x: i32) -> i32 { x + 1 }

pub fn beta(s: &str) -> &str { s }

struct Holder { v: Vec<u8> }
impl Holder {
    pub fn new() -> Self { Self { v: vec![] } }
}
"#;
        let chunks = TreeSitterChunker::new().chunk(source, Language::Rust);
        // Expect at least: alpha, beta, struct Holder, impl Holder.
        assert!(chunks.len() >= 3, "got {} chunks", chunks.len());
        let kinds: Vec<_> = chunks
            .iter()
            .filter_map(|c| c.node_kind.as_deref())
            .collect();
        assert!(kinds.contains(&"function_item"));
    }

    #[test]
    fn tree_sitter_python_falls_back_for_unparseable() {
        // Garbage that still has known characters — the parser will
        // produce ERROR nodes; we should still produce some chunks
        // (line-window fallback if AST yields nothing).
        let source = "@#$%^&*()\nfn foo bar {{{ syntax error\n";
        let chunks = TreeSitterChunker::new().chunk(source, Language::Python);
        // Either AST extracted something or line-window did — never empty.
        assert!(!chunks.is_empty());
    }
}
