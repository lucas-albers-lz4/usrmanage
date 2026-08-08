# CLAUDE.md

Project guidance for Claude Code / agents working in this repository.

**Read and follow [AGENTS.md](AGENTS.md)** — source of truth for product locks, LuCI/rpc, security, testing, and release.

Quick reminders:

- Password policy defaults to **OpenWrt**; harden only after explicit Save.
- Never put passwords on argv, audit logs, or Playwright/MCP traces.
- LuCI `expect: { '': { ... } }` for whole-object RPC replies.
- Done gate: `./scripts/smoke-host.sh`. Lab e2e: `./scripts/playwright-luci.sh`. MCP: `.cursor/mcp.json`.
- Lab: `:2222` SSH / `:8080` LuCI; fixture users are not product defaults. Docs screenshots (#15): clean table, WebP.
- Release: third-octet `PKG_VERSION`, tag `v*`, Pages feed — see [docs/release.md](docs/release.md).
- Security backlog: issue #3.
