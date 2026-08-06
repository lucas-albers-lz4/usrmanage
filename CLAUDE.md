# CLAUDE.md

Project guidance for Claude Code / agents working in this repository.

**Read and follow [AGENTS.md](AGENTS.md)** — that file is the source of truth for product locks, LuCI/rpc conventions, security invariants, and workflows.

Quick reminders:

- Password policy defaults to **OpenWrt**; harden only after explicit Save.
- Never put passwords on argv or in audit logs.
- LuCI `expect: { '': { ... } }` for whole-object RPC replies.
- `./scripts/smoke-host.sh` before claiming done.
- Security backlog tracked in issue #3 (Zen MCR).
