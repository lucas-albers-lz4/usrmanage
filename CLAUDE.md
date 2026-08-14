# CLAUDE.md

Project guidance for Claude Code / agents working in this repository.

**Read and follow [AGENTS.md](AGENTS.md)** — source of truth for product locks, LuCI/rpc, security, testing, and release.

Quick reminders:

- Password policy defaults to **OpenWrt**; harden only after explicit Save.
- Never put passwords on argv, audit logs, or Playwright/MCP traces.
- LuCI `expect: { '': { ... } }` for whole-object RPC replies.
- Done gate: `./scripts/smoke-host.sh`.
- Security review state (proof class, open findings): [docs/security-review.md](docs/security-review.md).
