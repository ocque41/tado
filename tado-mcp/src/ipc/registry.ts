import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";

const IPC_ROOT = "/tmp/tado-ipc";

export interface SessionEntry {
  sessionID: string;
  name: string;
  engine: string;
  gridLabel: string;
  status: string;
  projectName?: string;
  agentName?: string;
  teamName?: string;
  teamID?: string;
}

export function getIpcRoot(): string {
  // Follow symlink to actual ipc root
  return IPC_ROOT;
}

export async function readRegistry(): Promise<SessionEntry[]> {
  const registryPath = `${getIpcRoot()}/registry.json`;
  if (!existsSync(registryPath)) return [];
  try {
    const data = await readFile(registryPath, "utf-8");
    return JSON.parse(data) as SessionEntry[];
  } catch {
    return [];
  }
}

function parseGridLabel(label: string): [number, number] | null {
  // Accepts: "[1, 2]", "1,2", "1:2"
  const cleaned = label.replace(/[\[\]\s]/g, "");
  const parts = cleaned.split(/[,:]/).map(Number);
  if (parts.length === 2 && !isNaN(parts[0]) && !isNaN(parts[1])) {
    return [parts[0], parts[1]];
  }
  return null;
}

function normalizeGrid(input: string): string | null {
  const parsed = parseGridLabel(input);
  if (!parsed) return null;
  return `[${parsed[0]}, ${parsed[1]}]`;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function resolveTarget(
  entries: SessionEntry[],
  target: string,
  projectFilter?: string,
  teamFilter?: string,
): SessionEntry | null {
  let filtered = entries;

  if (projectFilter) {
    filtered = filtered.filter(
      (e) => e.projectName?.toLowerCase() === projectFilter.toLowerCase(),
    );
  }
  if (teamFilter) {
    filtered = filtered.filter(
      (e) => e.teamName?.toLowerCase() === teamFilter.toLowerCase(),
    );
  }

  // 1. Exact UUID match
  if (UUID_RE.test(target)) {
    const lower = target.toLowerCase();
    return filtered.find((e) => e.sessionID.toLowerCase() === lower) ?? null;
  }

  // 2. Grid coordinate match
  const normalizedGrid = normalizeGrid(target);
  if (normalizedGrid) {
    const match = filtered.find((e) => e.gridLabel === normalizedGrid);
    if (match) return match;
  }

  // 3. Name substring match
  const lower = target.toLowerCase();
  const matches = filtered.filter((e) => e.name.toLowerCase().includes(lower));
  if (matches.length === 1) return matches[0];

  return null;
}
