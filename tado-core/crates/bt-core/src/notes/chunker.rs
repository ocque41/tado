//! Heading-aware markdown chunker.
//!
//! Splits a note into chunks suitable for embedding. The algorithm is
//! deliberately simple and deterministic so the same input always
//! produces the same chunks — that stability matters for incremental
//! reindex, since we can compare byte offsets to decide which chunks
//! changed.
//!
//! # Strategy
//!
//! 1. Walk lines. Start a new chunk whenever we hit an ATX heading
//!    (`#`, `##`, …). This keeps chunks aligned with the user's own
//!    section boundaries instead of slicing through them.
//! 2. Within a single heading's section, if the accumulated chunk
//!    exceeds `SOFT_CHAR_TARGET`, flush early at the next blank line.
//!    This caps chunk length without ever splitting inside a paragraph.
//! 3. Hard cap: if a single run still exceeds `HARD_CHAR_CAP`, flush
//!    at the current line boundary. Protects against pathological
//!    single-paragraph notes.
//!
//! Each chunk records the byte range it occupies in the source
//! markdown (`byte_range`) so a caller can diff chunks against a newer
//! version of the same note cheaply.
//!
//! # What this is not
//!
//! - No tokenizer. Character counts are a reasonable proxy for token
//!   counts when the embedder runs on English prose; we'll swap in a
//!   real token count once the embedder lands if it matters.
//! - No semantic splitting. Heading + blank-line is enough for the
//!   note-taking use case; fancier sentence-level splitting would be
//!   overfit for the note lengths we actually see.

/// Target character count per chunk when a natural boundary is available.
/// Roughly ~300 tokens of English prose.
pub const SOFT_CHAR_TARGET: usize = 1_200;

/// Hard upper bound before we force a split even mid-section.
pub const HARD_CHAR_CAP: usize = 2_400;

/// Byte range in the source markdown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ByteRange {
    pub start: usize,
    pub end: usize,
}

/// A single chunk of a note, ready to be embedded + stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    /// Zero-based position of this chunk inside the note, in chunker
    /// order. Stable across re-chunks of the same input.
    pub index: usize,
    /// Chunk text, trimmed of trailing whitespace.
    pub text: String,
    /// Byte range in the original markdown — `text` may be shorter
    /// than `end - start` because we trim trailing blanks.
    pub byte_range: ByteRange,
    /// Heading path this chunk sits under, from outermost to most
    /// specific. Empty if the chunk appears before any heading.
    /// Useful as extra context at embed time.
    pub heading_path: Vec<String>,
}

/// Chunk a markdown string into embedding-sized pieces.
///
/// Returns an empty vec for input that contains only whitespace; a
/// single chunk for short inputs; multiple chunks for long ones.
pub fn chunk_markdown(markdown: &str) -> Vec<Chunk> {
    if markdown.trim().is_empty() {
        return Vec::new();
    }

    let mut chunks: Vec<Chunk> = Vec::new();
    let mut current_text = String::new();
    let mut current_start: Option<usize> = None;
    let mut heading_stack: Vec<(usize, String)> = Vec::new();
    let mut current_heading_path: Vec<String> = Vec::new();
    let mut cursor: usize = 0;

    for line in markdown.split_inclusive('\n') {
        let line_start = cursor;
        let line_end = cursor + line.len();
        cursor = line_end;

        let trimmed_end = line.trim_end_matches(['\n', '\r']);
        if let Some((level, title)) = parse_atx_heading(trimmed_end) {
            // Flush anything we've accumulated before starting a new
            // section. We always split on headings so the heading path
            // attached to each chunk is stable.
            if !current_text.trim().is_empty() {
                flush_chunk(
                    &mut chunks,
                    &mut current_text,
                    current_start.unwrap_or(line_start),
                    line_start,
                    &current_heading_path,
                );
            }

            // Update the heading stack so nested sections carry the
            // outer titles. Pop any deeper-or-equal headings first.
            while let Some(&(last_level, _)) = heading_stack.last() {
                if last_level >= level {
                    heading_stack.pop();
                } else {
                    break;
                }
            }
            heading_stack.push((level, title.to_string()));
            current_heading_path = heading_stack.iter().map(|(_, t)| t.clone()).collect();

            // The heading line itself becomes the start of the new chunk
            // so the chunk text includes its own header for embedding
            // context.
            current_text.push_str(line);
            current_start = Some(line_start);
            continue;
        }

        if current_start.is_none() {
            current_start = Some(line_start);
        }
        current_text.push_str(line);

        let over_soft = current_text.trim_end().len() >= SOFT_CHAR_TARGET;
        let blank_line = trimmed_end.trim().is_empty();
        let over_hard = current_text.trim_end().len() >= HARD_CHAR_CAP;

        if (over_soft && blank_line) || over_hard {
            flush_chunk(
                &mut chunks,
                &mut current_text,
                current_start.unwrap_or(line_start),
                line_end,
                &current_heading_path,
            );
            current_start = None;
        }
    }

    if !current_text.trim().is_empty() {
        flush_chunk(
            &mut chunks,
            &mut current_text,
            current_start.unwrap_or(cursor),
            cursor,
            &current_heading_path,
        );
    }

    chunks
}

fn flush_chunk(
    chunks: &mut Vec<Chunk>,
    buf: &mut String,
    start: usize,
    end: usize,
    heading_path: &[String],
) {
    let trimmed = buf.trim_end().to_string();
    if trimmed.is_empty() {
        buf.clear();
        return;
    }
    let index = chunks.len();
    chunks.push(Chunk {
        index,
        text: trimmed,
        byte_range: ByteRange { start, end },
        heading_path: heading_path.to_vec(),
    });
    buf.clear();
}

/// Parse an ATX heading line (`#`, `##`, … up to `######`). Returns
/// `(level, title)` on match, where level is 1..=6.
fn parse_atx_heading(line: &str) -> Option<(usize, &str)> {
    let stripped = line.trim_start();
    if !stripped.starts_with('#') {
        return None;
    }
    let mut level = 0;
    for c in stripped.chars() {
        if c == '#' {
            level += 1;
            if level > 6 {
                return None;
            }
        } else if c == ' ' {
            break;
        } else {
            return None;
        }
    }
    if level == 0 {
        return None;
    }
    // Body is everything after the leading #s and a single space.
    let body = stripped[level..].trim_start().trim_end_matches('#').trim();
    if body.is_empty() {
        return None;
    }
    Some((level, body))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_returns_no_chunks() {
        assert!(chunk_markdown("").is_empty());
        assert!(chunk_markdown("   \n   ").is_empty());
    }

    #[test]
    fn short_input_single_chunk() {
        let chunks = chunk_markdown("hello world\n");
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].text, "hello world");
        assert_eq!(chunks[0].index, 0);
        assert!(chunks[0].heading_path.is_empty());
    }

    #[test]
    fn headings_start_new_chunks() {
        let md = r#"preamble line

# Alpha
alpha body line

# Beta
beta body line
"#;
        let chunks = chunk_markdown(md);
        assert_eq!(chunks.len(), 3);
        assert_eq!(chunks[0].heading_path, Vec::<String>::new());
        assert_eq!(chunks[1].heading_path, vec!["Alpha".to_string()]);
        assert_eq!(chunks[2].heading_path, vec!["Beta".to_string()]);
        assert!(chunks[1].text.contains("# Alpha"));
        assert!(chunks[2].text.contains("# Beta"));
    }

    #[test]
    fn nested_headings_build_path() {
        let md = r#"# Top
body

## Middle
inner

### Deep
more
"#;
        let chunks = chunk_markdown(md);
        assert_eq!(chunks.len(), 3);
        assert_eq!(chunks[0].heading_path, vec!["Top".to_string()]);
        assert_eq!(
            chunks[1].heading_path,
            vec!["Top".to_string(), "Middle".to_string()]
        );
        assert_eq!(
            chunks[2].heading_path,
            vec![
                "Top".to_string(),
                "Middle".to_string(),
                "Deep".to_string()
            ]
        );
    }

    #[test]
    fn sibling_headings_reset_path() {
        let md = r#"# A
## A1
a1 body
## A2
a2 body
# B
b body
"#;
        let chunks = chunk_markdown(md);
        assert_eq!(chunks.len(), 4);
        assert_eq!(chunks[0].heading_path, vec!["A".to_string()]);
        assert_eq!(
            chunks[1].heading_path,
            vec!["A".to_string(), "A1".to_string()]
        );
        assert_eq!(
            chunks[2].heading_path,
            vec!["A".to_string(), "A2".to_string()]
        );
        assert_eq!(chunks[3].heading_path, vec!["B".to_string()]);
    }

    #[test]
    fn byte_ranges_are_monotonic_and_nonoverlapping() {
        let md = r#"# One
body one

# Two
body two
"#;
        let chunks = chunk_markdown(md);
        assert!(chunks.len() >= 2);
        for win in chunks.windows(2) {
            assert!(win[0].byte_range.start <= win[0].byte_range.end);
            assert!(win[0].byte_range.end <= win[1].byte_range.start);
        }
    }

    #[test]
    fn soft_target_triggers_split_at_blank_line() {
        let big_para = "word ".repeat(SOFT_CHAR_TARGET);
        let md = format!("{big_para}\n\nsecond paragraph\n");
        let chunks = chunk_markdown(&md);
        assert!(chunks.len() >= 2, "expected a split, got {}", chunks.len());
    }

    #[test]
    fn hard_cap_forces_split_even_without_blank() {
        // The chunker splits at line boundaries; a single giant line
        // with no newlines stays as one chunk (and would be trimmed
        // upstream by the caller). What we verify here is the
        // hard-cap behaviour across a *stream* of consecutive
        // non-blank lines that together exceed HARD_CHAR_CAP — the
        // chunker must split mid-section rather than hold an
        // unbounded buffer.
        let mut md = String::new();
        for i in 0..(HARD_CHAR_CAP / 20 + 20) {
            md.push_str(&format!("line number {i} of many consecutive\n"));
        }
        let chunks = chunk_markdown(&md);
        assert!(
            chunks.len() >= 2,
            "expected at least two chunks, got {}",
            chunks.len()
        );
    }

    #[test]
    fn atx_heading_parser_rejects_malformed() {
        assert!(parse_atx_heading("#no-space").is_none());
        assert!(parse_atx_heading("####### too deep").is_none());
        assert!(parse_atx_heading("# ").is_none());
        assert!(parse_atx_heading("not a heading").is_none());
        assert_eq!(parse_atx_heading("# Alpha"), Some((1, "Alpha")));
        assert_eq!(parse_atx_heading("###   Beta   "), Some((3, "Beta")));
        assert_eq!(parse_atx_heading("## Gamma ##"), Some((2, "Gamma")));
    }

    #[test]
    fn indices_are_sequential_from_zero() {
        let md = "# a\n# b\n# c\n";
        let chunks = chunk_markdown(md);
        for (expected, chunk) in chunks.iter().enumerate() {
            assert_eq!(chunk.index, expected);
        }
    }
}
