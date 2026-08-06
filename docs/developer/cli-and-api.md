# CLI and API

## Commands

```text
# View (non-root allowed)
usrmanage list [--json] [--all]
usrmanage show <user> [--json]
usrmanage audit [--json] [--last N]
usrmanage doctor [--json]

# Manage (root)
usrmanage add <user> --role readonly|admin [--password-fd N] [--json]
usrmanage set-role <user> readonly|admin [--json]
usrmanage passwd <user> [--password-fd N] [--json]
usrmanage del <user> [--purge-home] [--json]
```

Environment:

| Variable | Purpose |
|----------|---------|
| `USRMANAGE_ACTOR` | Audit actor override (LuCI sets this) |
| `USRMANAGE_SRC` | `cli` or `luci` |

## ubus methods (rpcd)

| Method | ACL | Notes |
|--------|-----|-------|
| `list` | read | `{ "all": false }` |
| `show` | read | `{ "name": "…" }` |
| `audit` | read | `{ "last": 50 }` |
| `doctor` | read | self-check |
| `add` | write | `{ "name", "role", "password" }` → password to CLI via fd |
| `del` | write | `{ "name", "purge_home" }` |
| `set_role` | write | `{ "name", "role" }` |
| `passwd` | write | `{ "name", "password" }` |

## Audit event schema

Compact line (file + syslog):

```text
<ISO8601Z> <action> user=<name> [role=<role>] actor=<actor> src=<cli|luci> result=<ok|denied|fail> [reason=<code>]
```

Actions: `grant`, `remove`, `role`, `passwd`, `denied`, `fail`.

JSON (`usrmanage audit --json`):

```json
{
  "events": [
    {
      "ts": "2026-08-05T23:16:10Z",
      "action": "grant",
      "user": "audit",
      "role": "readonly",
      "actor": "jdoe",
      "src": "luci",
      "result": "ok"
    }
  ]
}
```

Claim level: **operational audit** only — see [security.md](../security.md).

## Username / password policy

- Username: `^[a-z_][a-z0-9_-]{0,31}$`, deny-list includes `root` and common system names
- Password: length ≥ 8, not equal to username, confirm match (UI)

## Prototypes

See [docs/prototype/api-shapes.json](../prototype/api-shapes.json) and [prototypes/cli-help.txt](../../prototypes/cli-help.txt).
