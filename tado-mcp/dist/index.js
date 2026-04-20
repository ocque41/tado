#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { tadoList } from "./tools/list.js";
import { tadoRead } from "./tools/read.js";
import { tadoSend } from "./tools/send.js";
import { tadoBroadcast } from "./tools/broadcast.js";
import { tadoConfigGet, tadoConfigSet, tadoConfigList, } from "./tools/config.js";
import { tadoMemoryRead, tadoMemoryAppend, tadoMemorySearch, } from "./tools/memory.js";
import { tadoNotify, tadoEventsQuery } from "./tools/events.js";
const server = new McpServer({
    name: "tado-mcp",
    version: "0.1.0",
});
server.registerTool("tado_list", {
    title: "List Tado Sessions",
    description: "List all active Tado terminal sessions with their ID, engine, grid position, status, project, and name. Use this to discover which AI coding agents are currently running in Tado before sending messages or reading their output.",
    inputSchema: {
        project: z.string().optional().describe("Filter by project name"),
        team: z.string().optional().describe("Filter by team name"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoList(args) }],
}));
server.registerTool("tado_read", {
    title: "Read Tado Session Output",
    description: "Read the terminal output of a Tado session. Target can be a grid coordinate (e.g. '1,1'), session name substring, or UUID. Use tado_list first to see available targets.",
    inputSchema: {
        target: z
            .string()
            .describe("Grid coord (1,1), name substring, or UUID"),
        tail: z
            .number()
            .optional()
            .describe("Only return last N lines of output"),
        project: z.string().optional().describe("Filter by project name"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoRead(args) }],
}));
server.registerTool("tado_send", {
    title: "Send Message to Tado Session",
    description: "Send typed input to a Tado terminal session. The message will appear as if typed into the terminal. Target can be a grid coordinate (e.g. '1,1'), session name substring, or UUID. Use tado_list first to see available targets.",
    inputSchema: {
        target: z
            .string()
            .describe("Grid coord (1,1), name substring, or UUID"),
        message: z.string().describe("The message to send to the agent"),
        project: z.string().optional().describe("Filter by project name"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoSend(args) }],
}));
server.registerTool("tado_broadcast", {
    title: "Broadcast to Tado Sessions",
    description: "Send a message to all active Tado sessions, optionally filtered by project or team. Useful for coordinating multiple agents simultaneously.",
    inputSchema: {
        message: z.string().describe("The message to broadcast to all agents"),
        project: z.string().optional().describe("Filter by project name"),
        team: z.string().optional().describe("Filter by team name"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoBroadcast(args) }],
}));
// --- Packet 8: settings / memory / events / notify surface ---
server.registerTool("tado_config_get", {
    title: "Read Tado setting",
    description: "Read a dotted key from Tado's settings. Scope: 'global' (user-wide), 'project' (committed .tado/config.json), or 'project-local' (gitignored .tado/local.json). Project scope requires running inside a Tado project.",
    inputSchema: {
        scope: z.string().describe("global | project | project-local"),
        key: z.string().describe("Dotted path, e.g. 'ui.bellMode' or 'engine.claude.effort'"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoConfigGet(args) }],
}));
server.registerTool("tado_config_set", {
    title: "Write Tado setting",
    description: "Atomically update a dotted key in Tado's settings. Write is serialized through the same rename-based atomic store used by the Swift app, so edits from multiple sources don't tear.",
    inputSchema: {
        scope: z.string().describe("global | project | project-local"),
        key: z.string().describe("Dotted path"),
        value: z.union([z.string(), z.number(), z.boolean(), z.null()]).describe("Value to write. Strings that parse as JSON (true, 42, {}) are coerced."),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoConfigSet(args) }],
}));
server.registerTool("tado_config_list", {
    title: "Dump Tado settings",
    description: "Return the full contents of a settings file for the given scope.",
    inputSchema: {
        scope: z.string().optional().describe("Defaults to 'global'"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoConfigList(args) }],
}));
server.registerTool("tado_memory_read", {
    title: "Read Tado memory",
    description: "Return the markdown content of Tado's long-lived memory. Scope: 'user' (cross-project) or 'project' (this project only, requires running inside a Tado project).",
    inputSchema: {
        scope: z.string().optional().describe("user | project (default: project)"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoMemoryRead(args) }],
}));
server.registerTool("tado_memory_append", {
    title: "Append to Tado memory",
    description: "Append a timestamped note to Tado memory. Use this to persist durable facts across runs — user preferences, decisions, gotchas. Notes survive app restart and show up in future agent spawns (for project scope) or across every agent (for user scope).",
    inputSchema: {
        text: z.string().describe("The note text to append"),
        scope: z.string().optional().describe("user | project (default: project)"),
        tags: z.array(z.string()).optional().describe("Optional tags — surfaced in the note header"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoMemoryAppend(args) }],
}));
server.registerTool("tado_memory_search", {
    title: "Search Tado memory",
    description: "Case-insensitive substring search across user + project memory. Returns up to 100 hits with file:line:context.",
    inputSchema: {
        query: z.string().describe("Substring to match"),
        scope: z.string().optional().describe("user | project | all (default: all)"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoMemorySearch(args) }],
}));
server.registerTool("tado_notify", {
    title: "Publish Tado notification",
    description: "Emit a user-visible event to Tado's notification system — shows an in-app banner and (if the app is backgrounded) a macOS system notification. Useful for agents to surface milestones or failures without shouting in the terminal.",
    inputSchema: {
        title: z.string().describe("Short title — under 80 chars"),
        body: z.string().optional().describe("Longer body text"),
        severity: z.enum(["info", "success", "warning", "error"]).optional(),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoNotify(args) }],
}));
server.registerTool("tado_events_query", {
    title: "Query Tado event log",
    description: "Read the most recent Tado events, filtered by type/severity/since. Returns newest-first, up to the specified limit.",
    inputSchema: {
        since: z.string().optional().describe("ISO timestamp lower bound (e.g. '2026-04-20T00:00:00Z')"),
        type: z.string().optional().describe("Exact event type, e.g. 'eternal.phaseCompleted'"),
        severity: z.string().optional().describe("info | success | warning | error"),
        limit: z.number().optional().describe("Default 100"),
    },
}, async (args) => ({
    content: [{ type: "text", text: await tadoEventsQuery(args) }],
}));
async function main() {
    const transport = new StdioServerTransport();
    await server.connect(transport);
}
main().catch((err) => {
    console.error("Fatal:", err);
    process.exit(1);
});
