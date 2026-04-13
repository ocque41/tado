import { writeFile, mkdir } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { getIpcRoot } from "./registry.js";

export interface IpcMessage {
  id: string;
  from: string;
  fromName: string;
  to: string;
  timestamp: string;
  body: string;
  status: "pending";
}

const NULL_UUID = "00000000-0000-0000-0000-000000000000";

export async function sendMessage(
  targetSessionID: string,
  body: string,
  fromName = "mcp-server",
): Promise<string> {
  const ipcRoot = getIpcRoot();
  const inboxDir = `${ipcRoot}/a2a-inbox`;
  await mkdir(inboxDir, { recursive: true });

  const msgId = randomUUID();
  const msg: IpcMessage = {
    id: msgId,
    from: NULL_UUID,
    fromName,
    to: targetSessionID,
    timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    body,
    status: "pending",
  };

  const msgPath = `${inboxDir}/${msgId}.msg`;
  await writeFile(msgPath, JSON.stringify(msg, null, 2));
  return msgId;
}
