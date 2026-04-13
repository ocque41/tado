#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { tadoList } from "./tools/list.js";
import { tadoRead } from "./tools/read.js";
import { tadoSend } from "./tools/send.js";
import { tadoBroadcast } from "./tools/broadcast.js";
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
async function main() {
    const transport = new StdioServerTransport();
    await server.connect(transport);
}
main().catch((err) => {
    console.error("Fatal:", err);
    process.exit(1);
});
