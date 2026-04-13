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

## Contacting Other Agents

When you send a message to another agent via `tado-send`, you **must** identify yourself and tell the recipient how to reach you. The receiving agent has no context about who sent the message unless you include it.

**Always include in your message:**
1. **Who you are** — your grid position, project name, or a short description of your task
2. **How to respond** — the grid coordinate or name the recipient should use with `tado-send` to reply

**Good example:**
```bash
tado-send 2,1 "Hey, I'm the agent at [1,1] working on the auth module in the cumulus project. Can you share the API schema you generated? Reply with: tado-send 1,1 \"<your response>\""
```

**Bad example (don't do this):**
```bash
tado-send 2,1 "Can you share the API schema?"
# The recipient has no idea who asked or how to reply
```

This applies to every first contact with another agent. Once a conversation is established and both agents know each other's coordinates, you can skip the full introduction.

## Team Coordination

When you are part of a team, you share a project with other specialized agents. Each teammate has a defined role.

**Know your teammates:**
- Read their agent definition files at `.claude/agents/<name>.md` or `.codex/agents/<name>.md` to understand what each teammate does
- Use `tado-list` to see which teammates are currently running

**When you need something from a teammate:**
- Send a clear request via `tado-send`, identifying yourself and what you need
- The teammate is obligated to deliver — they will respond via `tado-send` back to you
- Use `tado-read <teammate>` to check their recent output for context before asking

**When a teammate asks you for something:**
- **You MUST deliver.** Read what they need, produce it, and send it back via `tado-send`
- Do not just work on it silently — the requesting agent is waiting for your `tado-send` response
- Deliver the actual content they asked for, not just a status update

**Team workflow pattern:**
1. `tado-list` — find your running teammates
2. `tado-send <teammate> "I'm '<role>' on team '<name>'. I need <what>. Reply with: tado-send <your-grid> '<response>'"` — request
3. When you receive a request from a teammate — deliver what they asked via `tado-send`

## Responding to Agent Requests (Mandatory)

**When another agent asks you for something, you MUST deliver.** Do not ignore it, do not just acknowledge it in your local chat. You are obligated to send back the requested information or result via `tado-send`.

**The rule is simple:** if an agent asks you a question or requests output, you respond with the answer using `tado-send <their-grid> "<your response>"`. This is not optional. The requesting agent is blocked until you deliver.

**Example:** An agent at [2,1] sends you: "I'm the backend agent at [2,1]. I need the API types you generated. Reply with: tado-send 2,1 '<types>'"
- You MUST run `tado-send 2,1 "Here are the types: ..."` with the actual content
- Do NOT just print the answer in your own terminal and hope they read it
- Do NOT say "I'll get back to you" — deliver now

## Message Origin Rules

Tado's prompt transport may not clearly tell you whether a message came from the human user or from another terminal. Use the message content to decide.

- Treat the message as **agent-originated** when it clearly self-identifies as a terminal or session, for example:
  - `"I'm the agent at 3,1"`
  - `"agent 2,1 here"`
  - first-person questions about another terminal's conversation or output
- For agent-originated messages:
  - **you MUST respond back** with what they asked for via `tado-send <target> "<response>"`
  - use `tado-list` to resolve the sender if needed
  - deliver the requested information, do not just acknowledge the message
  - if useful, also tell the human user what you did
- Treat the message as **user-originated** when it does not clearly identify itself as another terminal.
- If origin is ambiguous and the distinction matters, make the safest assumption and say it briefly.

Rule of thumb: if an agent asks you for something, deliver it back to them through `tado-send`. They are waiting for your response.

## Build & Run

```bash
swift build          # Build the project
swift run            # Build and run the app
```

The project uses Swift Package Manager (swift-tools-version 5.10, macOS 14+). No tests exist yet.

## For full architecture details, see CLAUDE.md in this same directory.
