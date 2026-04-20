import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { paths, projectMemoryPath, projectNotesDir } from "../paths.js";

/// Resolve a memory scope to its markdown file path.
function resolveFile(scope: string): string {
  switch (scope) {
    case "user":
      return paths.userMemoryMarkdown;
    case "project":
      {
        const p = projectMemoryPath();
        if (!p)
          throw new Error(
            `No .tado/ directory found above ${process.cwd()} — cannot resolve project memory scope.`,
          );
        return p;
      }
    default:
      throw new Error(`unknown scope: ${scope} (expected: user | project)`);
  }
}

async function ensureFile(path: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  if (!existsSync(path)) await writeFile(path, "", "utf-8");
}

export async function tadoMemoryRead(args: {
  scope?: string;
}): Promise<string> {
  const scope = args.scope ?? "project";
  const path = resolveFile(scope);
  if (!existsSync(path)) return `(empty — no ${scope} memory file yet at ${path})`;
  return await readFile(path, "utf-8");
}

export async function tadoMemoryAppend(args: {
  text: string;
  scope?: string;
  tags?: string[];
}): Promise<string> {
  if (!args.text.trim()) return "refusing to append empty note";
  const scope = args.scope ?? "project";
  const path = resolveFile(scope);
  await ensureFile(path);

  const iso = new Date().toISOString();
  const tagLine =
    args.tags && args.tags.length > 0 ? `\n_tags: ${args.tags.join(", ")}_` : "";
  const entry = `\n\n## ${iso}${tagLine}\n\n${args.text.trim()}\n`;
  await writeFile(path, entry, { flag: "a", encoding: "utf-8" });
  return `appended ${args.text.length} chars to ${path}`;
}

export async function tadoMemorySearch(args: {
  query: string;
  scope?: string;
}): Promise<string> {
  const q = args.query.toLowerCase();
  const scope = args.scope ?? "all";

  const files: string[] = [];
  if (scope === "user" || scope === "all") files.push(paths.userMemoryMarkdown);
  if (scope === "project" || scope === "all") {
    const p = projectMemoryPath();
    if (p) files.push(p);
    const notesDir = projectNotesDir();
    if (notesDir && existsSync(notesDir)) {
      for (const entry of readdirSync(notesDir)) {
        if (entry.endsWith(".md")) files.push(join(notesDir, entry));
      }
    }
  }

  const hits: string[] = [];
  for (const file of files) {
    if (!existsSync(file)) continue;
    try {
      const lines = readFileSync(file, "utf-8").split("\n");
      lines.forEach((line, idx) => {
        if (line.toLowerCase().includes(q)) {
          hits.push(`${file}:${idx + 1}: ${line.trim()}`);
        }
      });
    } catch {
      /* skip */
    }
  }
  if (hits.length === 0) return `no matches for "${args.query}"`;
  return hits.slice(0, 100).join("\n");
}
