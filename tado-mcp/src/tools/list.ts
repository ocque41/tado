import { readRegistry, type SessionEntry } from "../ipc/registry.js";

export async function tadoList(args: {
  project?: string;
  team?: string;
}): Promise<string> {
  const entries = await readRegistry();

  let filtered = entries;
  if (args.project) {
    filtered = filtered.filter(
      (e) => e.projectName?.toLowerCase() === args.project!.toLowerCase(),
    );
  }
  if (args.team) {
    filtered = filtered.filter(
      (e) => e.teamName?.toLowerCase() === args.team!.toLowerCase(),
    );
  }

  if (filtered.length === 0) {
    return "No active Tado sessions found.";
  }

  return formatTable(filtered);
}

function formatTable(entries: SessionEntry[]): string {
  const header = ["Grid", "Engine", "Status", "Project", "Team", "Agent", "Name", "ID"];
  const rows = entries.map((e) => [
    e.gridLabel,
    e.engine,
    e.status,
    e.projectName ?? "-",
    e.teamName ?? "-",
    e.agentName ?? "-",
    e.name.length > 50 ? e.name.slice(0, 47) + "..." : e.name,
    e.sessionID.slice(0, 8),
  ]);

  const widths = header.map((h, i) =>
    Math.max(h.length, ...rows.map((r) => r[i].length)),
  );

  const sep = widths.map((w) => "-".repeat(w)).join(" | ");
  const fmt = (row: string[]) =>
    row.map((c, i) => c.padEnd(widths[i])).join(" | ");

  return [fmt(header), sep, ...rows.map(fmt)].join("\n");
}
