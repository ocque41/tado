import { writeFile, mkdir } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { getIpcRoot } from "./registry.js";
const NULL_UUID = "00000000-0000-0000-0000-000000000000";
export async function sendMessage(targetSessionID, body, fromName = "mcp-server") {
    const ipcRoot = getIpcRoot();
    const inboxDir = `${ipcRoot}/a2a-inbox`;
    await mkdir(inboxDir, { recursive: true });
    const msgId = randomUUID();
    const msg = {
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
