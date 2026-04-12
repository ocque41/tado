# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability in Tado, please report it responsibly:

1. **Email**: Send a description to **hi@cumulush.com**
2. **Do not** open a public GitHub issue for security vulnerabilities
3. Include steps to reproduce the issue if possible

You should receive an acknowledgment within 7 days. We will work with you to understand the issue and coordinate a fix.

## Scope

This policy covers the Tado macOS application itself. It does **not** cover the third-party CLI tools it invokes (Claude Code, Codex) or their respective APIs.

## IPC Security Note

Tado uses a file-based IPC system under `/tmp/tado-ipc-<pid>/` for inter-session messaging. This directory is created with default user permissions and cleaned up on application exit. The IPC system is designed for local, single-user use only.
