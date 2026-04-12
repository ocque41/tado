# AGENTS.md

This file provides guidance to Codex CLI when working with code in this repository.

## What This Is

Tado is a macOS app that runs multiple AI coding agents as terminal tiles. You are one of those agents. Other agents (Claude Code or Codex) are running in sibling terminals on the same canvas.

## Tado A2A (Agent-to-Agent IPC)

You have CLI tools available for inter-terminal communication. **Use these when asked to message, respond to, or interact with other Tado terminals.**

```bash
tado-list                          # List all active sessions (ID, engine, grid, status, name)
tado-read <target> [--tail N] [--follow] [--raw]  # Read terminal output from a session
tado-send <target> <message>       # Send typed input to a terminal session
```

**Target resolution** (same for `tado-read` and `tado-send`, in priority order):
1. Exact UUID
2. Grid coordinates: `1,1` or `1:1` or `[1,1]`
3. Name substring match

**Examples:**
```bash
tado-list                                      # See who else is running
tado-read 1,1                                  # Read full output from terminal at grid [1,1]
tado-read 1,1 --tail 50                        # Last 50 lines only
tado-read hello --follow                       # Live-stream output (like tail -f)
tado-send 1,1 "hello from another agent"       # Send to terminal at grid [1,1]
tado-send hello "follow-up prompt"             # Send to session whose name contains "hello"
```

**Typical workflow for responding to a terminal:** `tado-list` to see active sessions, `tado-read 1,1` to see what it output, then `tado-send 1,1 "your response"` to reply.

## Message Origin Rules

Tado's prompt transport may not clearly tell you whether a message came from the human user or from another terminal. Use the message content to decide.

- Treat the message as **agent-originated** when it clearly self-identifies as a terminal or session, for example:
  - `"I'm the agent at 3,1"`
  - `"agent 2,1 here"`
  - first-person questions about another terminal's conversation or output
- For agent-originated messages:
  - do not reply only in the local user chat
  - use `tado-list` to resolve the sender if needed
  - use `tado-read` to verify any claimed conversation or output before answering
  - reply back to that terminal with `tado-send <target> "<message>"`
  - if useful, also tell the human user what you did
- Treat the message as **user-originated** when it does not clearly identify itself as another terminal.
- If origin is ambiguous and the distinction matters, make the safest assumption and say it briefly.

Rule of thumb: if a prompt says it is from another agent, answer that agent through Tado IPC, not just in this terminal's chat.

## Build & Run

```bash
swift build          # Build the project
swift run            # Build and run the app
```

The project uses Swift Package Manager (swift-tools-version 5.10, macOS 14+). No tests exist yet.

## For full architecture details, see CLAUDE.md in this same directory.
