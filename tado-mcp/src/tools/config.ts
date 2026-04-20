import {
  paths,
  projectConfigPath,
  projectLocalPath,
  readJSON,
  writeJSONAtomic,
} from "../paths.js";

/// Resolve a scope name to the absolute JSON path, or throw a
/// human-readable error if the scope is unknown / no project found.
function resolvePath(scope: string): string {
  switch (scope) {
    case "global":
      return paths.globalSettings;
    case "project":
    case "project-shared":
      {
        const p = projectConfigPath();
        if (!p) throw new Error(`No .tado/ directory found above ${process.cwd()}`);
        return p;
      }
    case "project-local":
    case "local":
      {
        const p = projectLocalPath();
        if (!p) throw new Error(`No .tado/ directory found above ${process.cwd()}`);
        return p;
      }
    default:
      throw new Error(
        `unknown scope: ${scope} (expected: global | project | project-local)`,
      );
  }
}

function navigate(obj: Record<string, unknown>, key: string): unknown {
  let cursor: unknown = obj;
  for (const part of key.split(".")) {
    if (typeof cursor !== "object" || cursor === null) return undefined;
    cursor = (cursor as Record<string, unknown>)[part];
  }
  return cursor;
}

function setPath(
  obj: Record<string, unknown>,
  key: string,
  value: unknown,
): void {
  const parts = key.split(".");
  let cursor = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    const part = parts[i];
    if (typeof cursor[part] !== "object" || cursor[part] === null) {
      cursor[part] = {};
    }
    cursor = cursor[part] as Record<string, unknown>;
  }
  cursor[parts[parts.length - 1]] = value;
}

export async function tadoConfigGet(args: {
  scope: string;
  key: string;
}): Promise<string> {
  const path = resolvePath(args.scope);
  const data = (await readJSON<Record<string, unknown>>(path)) ?? {};
  const value = navigate(data, args.key);
  if (value === undefined) return `(unset)`;
  return typeof value === "string" ? value : JSON.stringify(value, null, 2);
}

export async function tadoConfigSet(args: {
  scope: string;
  key: string;
  value: unknown;
}): Promise<string> {
  const path = resolvePath(args.scope);
  const data = (await readJSON<Record<string, unknown>>(path)) ?? {};

  // Best-effort: try parsing string values as JSON (so "true" → true,
  // "42" → 42) since MCP callers often pass strings uniformly. Falls
  // back to the raw string.
  let coerced: unknown = args.value;
  if (typeof args.value === "string") {
    try {
      coerced = JSON.parse(args.value);
    } catch {
      /* leave as string */
    }
  }

  setPath(data, args.key, coerced);
  data.writer = "tado-mcp";
  data.updatedAt = new Date().toISOString();
  await writeJSONAtomic(path, data);
  return `set ${args.scope}.${args.key}`;
}

export async function tadoConfigList(args: {
  scope?: string;
}): Promise<string> {
  const scope = args.scope ?? "global";
  const path = resolvePath(scope);
  const data = (await readJSON<Record<string, unknown>>(path)) ?? {};
  return JSON.stringify(data, null, 2);
}
