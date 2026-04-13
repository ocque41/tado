import { readRegistry, resolveTarget } from "../ipc/registry.js";
import { readSessionLog } from "../ipc/logs.js";
export async function tadoRead(args) {
    const entries = await readRegistry();
    const session = resolveTarget(entries, args.target, args.project);
    if (!session) {
        const available = entries
            .map((e) => `  ${e.gridLabel} ${e.name.slice(0, 40)}`)
            .join("\n");
        return `Could not resolve target "${args.target}". Available sessions:\n${available || "  (none)"}`;
    }
    return readSessionLog(session.sessionID, args.tail);
}
