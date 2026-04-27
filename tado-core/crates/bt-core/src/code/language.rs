//! Language detection by file extension. Returns `Language::Other` for
//! files we still want to index but don't have an AST grammar for —
//! those go through the `LineWindowChunker`.
//!
//! ## Why a closed enum
//!
//! Tree-sitter grammars are heavy compile-time deps. We bundle four
//! languages where the recall lift from AST chunking is largest in
//! this codebase (Swift/Rust/TS/Python). Anything else — Go, Java,
//! C/C++, JS, Markdown, configs — gets the same overlapping-line-window
//! treatment, which is ~80% of tree-sitter quality at zero compile
//! cost. Adding a language is a one-line Cargo addition + a match arm
//! here + a `pub fn ts_language` arm.

use std::path::Path;

/// Languages we recognize. The string form (`as_str`) is what gets
/// stored in `code_chunks.language` and queried from the UI; keep it
/// lowercase and stable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Language {
    Swift,
    Rust,
    TypeScript,
    Tsx,
    JavaScript,
    Jsx,
    Python,
    Go,
    Java,
    Kotlin,
    C,
    Cpp,
    Header,
    Markdown,
    Json,
    Yaml,
    Toml,
    Shell,
    /// Anything else with a known extension we still want to index.
    Other,
}

impl Language {
    /// Map a path's extension (lowercased) to a language. Files
    /// without a matching extension return `None` and the walker
    /// skips them.
    pub fn from_path(path: &Path) -> Option<Self> {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase())?;
        Some(match ext.as_str() {
            "swift" => Self::Swift,
            "rs" => Self::Rust,
            "ts" => Self::TypeScript,
            "tsx" => Self::Tsx,
            "js" | "mjs" | "cjs" => Self::JavaScript,
            "jsx" => Self::Jsx,
            "py" | "pyi" => Self::Python,
            "go" => Self::Go,
            "java" => Self::Java,
            "kt" | "kts" => Self::Kotlin,
            "c" | "m" => Self::C,
            "cpp" | "cc" | "cxx" | "mm" => Self::Cpp,
            "h" | "hpp" | "hh" | "hxx" => Self::Header,
            "md" | "markdown" => Self::Markdown,
            "json" => Self::Json,
            "yaml" | "yml" => Self::Yaml,
            "toml" => Self::Toml,
            "sh" | "bash" | "zsh" => Self::Shell,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Swift => "swift",
            Self::Rust => "rust",
            Self::TypeScript => "typescript",
            Self::Tsx => "tsx",
            Self::JavaScript => "javascript",
            Self::Jsx => "jsx",
            Self::Python => "python",
            Self::Go => "go",
            Self::Java => "java",
            Self::Kotlin => "kotlin",
            Self::C => "c",
            Self::Cpp => "cpp",
            Self::Header => "c-header",
            Self::Markdown => "markdown",
            Self::Json => "json",
            Self::Yaml => "yaml",
            Self::Toml => "toml",
            Self::Shell => "shell",
            Self::Other => "other",
        }
    }

    /// Tree-sitter grammar handle for languages we AST-chunk. Returns
    /// `None` for everything else; the `LineWindowChunker` picks them
    /// up.
    pub fn ts_language(self) -> Option<tree_sitter::Language> {
        match self {
            Self::Swift => Some(tree_sitter_swift::LANGUAGE.into()),
            Self::Rust => Some(tree_sitter_rust::LANGUAGE.into()),
            Self::TypeScript => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),
            Self::Tsx => Some(tree_sitter_typescript::LANGUAGE_TSX.into()),
            Self::Python => Some(tree_sitter_python::LANGUAGE.into()),
            _ => None,
        }
    }

    /// AST node kinds we treat as natural chunk boundaries for each
    /// language. Anything not matching falls through to descend into
    /// children. The list is intentionally narrow — a `function`
    /// inside a `class` becomes its own chunk; the surrounding class
    /// declaration also becomes a chunk minus its function bodies.
    pub fn chunk_node_kinds(self) -> &'static [&'static str] {
        match self {
            Self::Swift => &[
                "function_declaration",
                "init_declaration",
                "deinit_declaration",
                "class_declaration",
                "protocol_declaration",
                "extension_declaration",
                "struct_declaration",
                "enum_declaration",
            ],
            Self::Rust => &[
                "function_item",
                "impl_item",
                "trait_item",
                "struct_item",
                "enum_item",
                "mod_item",
            ],
            Self::TypeScript | Self::Tsx => &[
                "function_declaration",
                "method_definition",
                "class_declaration",
                "interface_declaration",
                "type_alias_declaration",
                "enum_declaration",
            ],
            Self::Python => &[
                "function_definition",
                "class_definition",
                "decorated_definition",
            ],
            _ => &[],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn extension_maps_to_language() {
        assert_eq!(Language::from_path(&PathBuf::from("foo.rs")), Some(Language::Rust));
        assert_eq!(Language::from_path(&PathBuf::from("Foo.SWIFT")), Some(Language::Swift));
        assert_eq!(Language::from_path(&PathBuf::from("foo.tsx")), Some(Language::Tsx));
        assert_eq!(Language::from_path(&PathBuf::from("foo.unknown")), None);
        assert_eq!(Language::from_path(&PathBuf::from("foo")), None);
    }

    #[test]
    fn ts_language_present_for_ast_languages() {
        assert!(Language::Rust.ts_language().is_some());
        assert!(Language::Swift.ts_language().is_some());
        assert!(Language::TypeScript.ts_language().is_some());
        assert!(Language::Python.ts_language().is_some());
        assert!(Language::Go.ts_language().is_none());
        assert!(Language::Markdown.ts_language().is_none());
    }
}
