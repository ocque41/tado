import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { getIpcRoot } from "./registry.js";

// Strip ANSI escape codes (CSI sequences, OSC sequences, etc.)
const ANSI_RE =
  // eslint-disable-next-line no-control-regex
  /(\x1b\[[0-9;]*[A-Za-z]|\x1b\].*?(?:\x07|\x1b\\)|\x1b[()][AB012]|\x1b[>=<]|\x1b\[[\?]?[0-9;]*[hlm])/g;

function stripAnsi(text: string): string {
  return text.replace(ANSI_RE, "");
}

export async function readSessionLog(
  sessionID: string,
  tail?: number,
): Promise<string> {
  const ipcRoot = getIpcRoot();
  const logPath = `${ipcRoot}/sessions/${sessionID.toLowerCase()}/log`;

  if (!existsSync(logPath)) {
    return `No log file found for session ${sessionID}`;
  }

  const raw = await readFile(logPath, "utf-8");
  const clean = stripAnsi(raw);

  if (tail && tail > 0) {
    const lines = clean.split("\n");
    return lines.slice(-tail).join("\n");
  }

  return clean;
}
