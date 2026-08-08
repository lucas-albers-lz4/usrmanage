# Testing

How usrmanage is tested locally and in CI. Passwords never appear on argv, in audit logs, or in Playwright/MCP traces (e2e keeps `trace: 'off'` for this reason).

## Layers

| Layer | What | Where | When |
|-------|------|-------|------|
| **Unit** | Validators, audit sanitize, theme (no hex), i18n POT coverage | `tests/test_validators.sh`, `tests/usrmanage-theme.test.js`, `tests/usrmanage-i18n.test.js` | PR via `./scripts/smoke-host.sh` |
| **Host integration** | Lock/flock, mutator denials under `USRMANAGE_DRY_RUN`, rpcd argv (no password leak) | `tests/test_mutators.sh`, `tests/test_mutators-busybox-fallback.sh` | PR via `./scripts/smoke-host.sh` |
| **Device integration** | Real `useradd`/wheel/ubus/HTTP page on guest | `scripts/qemu-smoke-usrmanage.sh` | Local (QEMU lab); not PR CI |
| **Playwright MCP** | Agent navigate/snapshot/click against live LuCI | `.cursor/mcp.json` → `@playwright/mcp` | Local with lab up |
| **E2E UI** | Committed LuCI user flows | `tests/e2e/` + `./scripts/playwright-luci.sh` | Local with lab up; not PR CI |

PR CI stays **host-only** (`usrmanage-test.yml` → `smoke-host.sh`) so merge gates stay fast.

## Host smoke

```sh
./scripts/smoke-host.sh
```

Runs shellcheck, package layout, validators, mutators, and (if `node` is present) theme + i18n checks.

## QEMU lab + CLI smoke

Prepare and boot an x86 image, install packages, then:

```sh
./scripts/qemu-smoke-usrmanage.sh
```

Defaults: SSH `127.0.0.1:2222`, LuCI `http://127.0.0.1:8080`, root with **empty** password on prepared images. Smoke may create fixture users such as `umadmin` — those are **test fixtures**, not product defaults.

See [README](../../README.md#qemu-lab-x86_64) and `scripts/qemu-*.sh`.

## Playwright MCP (agents)

Repo config: [`.cursor/mcp.json`](../../.cursor/mcp.json) (same pattern as fwlive). After clone, enable the server once in **Cursor Settings → MCP**.

- Prefer MCP for interactive LuCI exploration and selector authoring when the guest is up.
- Target `http://127.0.0.1:8080` (or `USRMANAGE_LUCI_URL`).
- Do not paste real passwords into prompts or leave them in MCP output; lab root password is empty after `qemu-lab-prepare-image.sh`.
- Screenshots land under `.cursor/browser-output/` (gitignored).

MCP does **not** replace the committed `@playwright/test` suite.

## Playwright e2e suite

Requires Node.js, Chromium browsers, and a running QEMU lab with `usrmanage` + `luci-app-usrmanage` installed.

```sh
npm install
npx playwright install chromium
# lab already prepared, booted, packages installed
./scripts/playwright-luci.sh
```

Environment:

| Variable | Default | Meaning |
|----------|---------|---------|
| `USRMANAGE_LUCI_URL` | `http://127.0.0.1:8080` | LuCI base URL |
| `USRMANAGE_LUCI_USER` | `root` | LuCI login |
| `USRMANAGE_LUCI_PASSWORD` | _(empty)_ | LuCI password (prepared lab) |
| `OPENWRT_HOST` | `127.0.0.1` | Guest for SSH cleanup |
| `OPENWRT_SSH_PORT` | `2222` | Guest SSH port |

Specs use unique usernames (`pwflow_*`) and clean up via SSH/`usrmanage del` when possible. English UI only for v1 e2e. Stable controls use `data-testid` (`usrmanage-add-user`, `usrmanage-add-username`, …) in the LuCI view.

## Related

- [luci-ux.md](luci-ux.md) — theme/i18n guards
- [supported-releases.md](../supported-releases.md) — smoke expectations per release
- [ROADMAP.md](../ROADMAP.md) — remaining QEMU matrix / i18n spotchecks
