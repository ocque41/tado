import { readRegistry } from "../ipc/registry.js";
import { sendMessage } from "../ipc/messages.js";
export async function tadoBroadcast(args) {
    const entries = await readRegistry();
    let targets = entries;
    if (args.project) {
        targets = targets.filter((e) => e.projectName?.toLowerCase() === args.project.toLowerCase());
    }
    if (args.team) {
        targets = targets.filter((e) => e.teamName?.toLowerCase() === args.team.toLowerCase());
    }
    if (targets.length === 0) {
        return "No matching sessions to broadcast to.";
    }
    const results = await Promise.all(targets.map((t) => sendMessage(t.sessionID, args.message)));
    return `Broadcast sent to ${results.length} session(s): ${targets.map((t) => t.gridLabel).join(", ")}`;
}
