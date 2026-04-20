import { homedir } from "node:os";
import { join, sep } from "node:path";
import { existsSync, mkdirSync, renameSync, writeFileSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
/// Shared filesystem path helpers for the Tado MCP server. Mirrors
/// Swift's `StorePaths` — identical locations so the Swift app,
/// CLI tools, and MCP all write through the same canonical files.
const APP_SUPPORT = join(homedir(), "Library", "Application Support", "Tado");
export const paths = {
    globalSettings: join(APP_SUPPORT, "settings", "global.json"),
    userMemoryMarkdown: join(APP_SUPPORT, "memory", "user.md"),
    eventsCurrent: join(APP_SUPPORT, "events", "current.ndjson"),
};
/// Walk up from `cwd` looking for a `.tado/` directory. Returns the
/// containing project root, or null if none found (user is outside
/// any Tado project).
export function findProjectRoot(cwd = process.cwd()) {
    let dir = cwd;
    while (dir !== sep) {
        if (existsSync(join(dir, ".tado")))
            return dir;
        const parent = dir.split(sep).slice(0, -1).join(sep) || sep;
        if (parent === dir)
            break;
        dir = parent;
    }
    return null;
}
export function projectConfigPath(cwd) {
    const root = findProjectRoot(cwd);
    return root ? join(root, ".tado", "config.json") : null;
}
export function projectLocalPath(cwd) {
    const root = findProjectRoot(cwd);
    return root ? join(root, ".tado", "local.json") : null;
}
export function projectMemoryPath(cwd) {
    const root = findProjectRoot(cwd);
    return root ? join(root, ".tado", "memory", "project.md") : null;
}
export function projectNotesDir(cwd) {
    const root = findProjectRoot(cwd);
    return root ? join(root, ".tado", "memory", "notes") : null;
}
/// Read JSON with defaults. Returns `null` if file missing, throws on
/// malformed JSON.
export async function readJSON(path) {
    if (!existsSync(path))
        return null;
    const raw = await readFile(path, "utf-8");
    return JSON.parse(raw);
}
/// Atomic write: write to `<path>.tmp-<pid>` then rename. Rename is
/// POSIX-atomic so readers always see either the old or new full file,
/// never a torn state. Creates parent directories if missing.
export async function writeJSONAtomic(path, value) {
    const parent = path.split(sep).slice(0, -1).join(sep);
    if (parent)
        mkdirSync(parent, { recursive: true });
    const tmp = `${path}.tmp-${process.pid}`;
    await writeFile(tmp, JSON.stringify(value, null, 2) + "\n", "utf-8");
    renameSync(tmp, path);
}
/// Append one NDJSON line. Uses plain appendFile — order-of-write is
/// serialized by the OS append; we accept a rare interleave risk
/// (shared with CLI tado-notify) in exchange for simplicity.
export async function appendNDJSON(path, value) {
    const parent = path.split(sep).slice(0, -1).join(sep);
    if (parent)
        mkdirSync(parent, { recursive: true });
    const line = JSON.stringify(value) + "\n";
    await writeFile(path, line, { flag: "a", encoding: "utf-8" });
}
/// Synchronous variants for cases where an MCP tool is already
/// inside an awaited handler but needs ordered writes in a loop.
export function writeJSONSyncAtomic(path, value) {
    const parent = path.split(sep).slice(0, -1).join(sep);
    if (parent)
        mkdirSync(parent, { recursive: true });
    const tmp = `${path}.tmp-${process.pid}`;
    writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", "utf-8");
    renameSync(tmp, path);
}
