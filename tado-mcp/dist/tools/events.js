import { existsSync, readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { appendNDJSON, paths } from "../paths.js";
function parseLine(line) {
    try {
        return JSON.parse(line);
    }
    catch {
        return null;
    }
}
export async function tadoNotify(args) {
    const event = {
        id: randomUUID(),
        ts: new Date().toISOString(),
        type: "user.broadcast",
        severity: args.severity ?? "info",
        source: { kind: "user" },
        title: args.title,
        body: args.body ?? "",
        actions: [],
        read: false,
    };
    await appendNDJSON(paths.eventsCurrent, event);
    return `published: ${event.id}`;
}
export async function tadoEventsQuery(args) {
    if (!existsSync(paths.eventsCurrent)) {
        return "(no events yet — tado has not published anything to this log)";
    }
    const lines = readFileSync(paths.eventsCurrent, "utf-8").split("\n");
    const sinceDate = args.since ? new Date(args.since).getTime() : -Infinity;
    const limit = args.limit ?? 100;
    const matched = [];
    // Iterate newest-first by walking from the end; cheap because we
    // stop once we have `limit` hits.
    for (let i = lines.length - 1; i >= 0; i--) {
        const raw = lines[i];
        if (!raw.trim())
            continue;
        const event = parseLine(raw);
        if (!event)
            continue;
        if (args.type && event.type !== args.type)
            continue;
        if (args.severity && event.severity !== args.severity)
            continue;
        if (sinceDate > 0 && new Date(event.ts).getTime() < sinceDate)
            continue;
        matched.push(event);
        if (matched.length >= limit)
            break;
    }
    if (matched.length === 0)
        return "(no matching events)";
    return matched
        .map((e) => `${e.ts}  [${e.severity.padEnd(7)}] ${e.type.padEnd(28)} ${e.title}`)
        .join("\n");
}
