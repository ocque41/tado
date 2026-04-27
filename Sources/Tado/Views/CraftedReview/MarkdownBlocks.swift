import Foundation

/// One block-level chunk of a parsed markdown document. The crafted.md
/// review modal renders a `[MarkdownBlock]` into SwiftUI views. The set
/// of cases is intentionally tight — headings, paragraphs, lists,
/// fenced code, dividers — because crafted.md is an architect-authored
/// brief, not arbitrary markdown. Tables, blockquotes, HTML, footnotes
/// pass through as paragraph text.
enum MarkdownBlock: Equatable {
    /// `# title` … `###### title`. `level` is 1...6. Used by the index
    /// to build the left sidebar (level 2 only).
    case heading(level: Int, text: String, slug: String)
    /// One run of paragraph text. Inline formatting (`**bold**`,
    /// `_italic_`, `code`, `[link](url)`) is preserved verbatim — the
    /// renderer feeds the raw string to `AttributedString(markdown:)`.
    case paragraph(String)
    /// `- item` / `* item` / `1. item`. The renderer handles bullet
    /// glyphs; we just hand it the items in order.
    case list(items: [String], ordered: Bool)
    /// ` ```lang ` block. `lang` is the optional fence info string
    /// (may be empty).
    case code(text: String, lang: String)
    /// `---` / `***` / `___` on a line by itself.
    case divider
}

enum MarkdownBlocks {
    /// Parse a markdown string into a flat sequence of blocks. Pure
    /// function — no I/O, no state. Designed to be cheap enough to run
    /// on every modal open without caching (a typical crafted.md is a
    /// few KB).
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // Normalize CRLF → LF so the line walker doesn't have to care.
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var i = 0
        var paragraphBuffer: [String] = []
        var listBuffer: [String] = []
        var listOrdered = false
        var inList = false

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard inList, !listBuffer.isEmpty else { return }
            blocks.append(.list(items: listBuffer, ordered: listOrdered))
            listBuffer.removeAll(keepingCapacity: true)
            inList = false
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block — consume until the closing fence. Lines
            // inside the fence are NOT re-parsed for headings/lists.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushList()
                let lang = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let codeRaw = lines[i]
                    let codeTrim = codeRaw.trimmingCharacters(in: .whitespaces)
                    if codeTrim.hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(codeRaw)
                    i += 1
                }
                blocks.append(.code(text: codeLines.joined(separator: "\n"), lang: lang))
                continue
            }

            // Empty line ends a paragraph or list.
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                i += 1
                continue
            }

            // Divider.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                flushList()
                blocks.append(.divider)
                i += 1
                continue
            }

            // Heading. Match 1–6 leading hashes followed by whitespace.
            if let (level, text) = parseHeading(trimmed) {
                flushParagraph()
                flushList()
                blocks.append(.heading(
                    level: level,
                    text: text,
                    slug: slugify(text)
                ))
                i += 1
                continue
            }

            // Bulleted list item.
            if let bullet = parseBulletItem(trimmed) {
                flushParagraph()
                if inList && listOrdered {
                    flushList()
                }
                inList = true
                listOrdered = false
                listBuffer.append(bullet)
                i += 1
                continue
            }

            // Ordered list item (`1. ...`).
            if let numbered = parseOrderedItem(trimmed) {
                flushParagraph()
                if inList && !listOrdered {
                    flushList()
                }
                inList = true
                listOrdered = true
                listBuffer.append(numbered)
                i += 1
                continue
            }

            // Regular paragraph line — accumulate.
            flushList()
            paragraphBuffer.append(trimmed)
            i += 1
        }

        flushParagraph()
        flushList()
        return blocks
    }

    /// Returns just the level-2 headings in order, suitable for the left
    /// sidebar. Level 1 is the document title (rendered in the body but
    /// not in the index — there's only one). Level 3+ render in the body
    /// but stay out of the sidebar so it doesn't get noisy.
    static func sectionIndex(_ blocks: [MarkdownBlock]) -> [(text: String, slug: String)] {
        blocks.compactMap { block in
            if case let .heading(level, text, slug) = block, level == 2 {
                return (text, slug)
            }
            return nil
        }
    }

    // MARK: - Internal helpers

    private static func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func parseBulletItem(_ line: String) -> String? {
        guard line.count >= 2 else { return nil }
        let first = line.first!
        guard first == "-" || first == "*" || first == "+" else { return nil }
        let second = line[line.index(after: line.startIndex)]
        guard second == " " else { return nil }
        let dropped = line.dropFirst(2)
        return String(dropped).trimmingCharacters(in: .whitespaces)
    }

    private static func parseOrderedItem(_ line: String) -> String? {
        var idx = line.startIndex
        var sawDigit = false
        while idx < line.endIndex, line[idx].isNumber {
            sawDigit = true
            idx = line.index(after: idx)
        }
        guard sawDigit, idx < line.endIndex, line[idx] == "." else { return nil }
        idx = line.index(after: idx)
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        idx = line.index(after: idx)
        return String(line[idx...]).trimmingCharacters(in: .whitespaces)
    }

    /// Anchor id for a heading. Lowercase ASCII alphanumerics; anything
    /// else collapses to a hyphen. Stable across runs so the sidebar
    /// can `scrollTo(slug)` without ambiguity. Duplicates are accepted —
    /// crafted.md heading collisions in practice are vanishingly rare,
    /// and a duplicate just scrolls to the first match.
    static func slugify(_ text: String) -> String {
        var out = ""
        var lastWasHyphen = false
        for scalar in text.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                out.append(Character(c.lowercased()))
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
