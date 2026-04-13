import { readRegistry, resolveTarget } from "../ipc/registry.js";
import { sendMessage } from "../ipc/messages.js";
export async function tadoSend(args) {
    const entries = await readRegistry();
    const session = resolveTarget(entries, args.target, args.project);
    if (!session) {
        const available = entries
            .map((e) => `  ${e.gridLabel} ${e.name.slice(0, 40)}`)
            .join("\n");
        return `Could not resolve target "${args.target}". Available sessions:\n${available || "  (none)"}`;
    }
    const msgId = await sendMessage(session.sessionID, args.message);
    return `Message sent to ${session.gridLabel} "${session.name.slice(0, 40)}" (msg: ${msgId.slice(0, 8)})`;
}
