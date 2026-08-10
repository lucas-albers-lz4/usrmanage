# CLI and API

## Commands

```text
# View (non-root allowed)
usrmanage list [--json] [--all]
usrmanage show <user> [--json]
usrmanage audit [--json] [--last N]
usrmanage doctor [--json]
usrmanage policy [--json] [--full]

# Manage (root)
usrmanage add <user> --role readonly|admin [--password-fd N] [--json]
usrmanage set-role <user> --role readonly|admin [--json]
usrmanage passwd <user> [--password-fd N] [--json]
usrmanage del <user> [--purge-home] [--json]
usrmanage set-policy --preset openwrt|standard|strict|custom [options] [--json]
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
| `policy` | read | policy name only |
| `get_policy` | read | full policy (preset + fields) |
| `add` | write | `{ "name", "role", "password" }` → password to CLI via fd |
| `del` | write | `{ "name", "purge_home" }` |
| `set_role` | write | `{ "name", "role" }` |
| `passwd` | write | `{ "name", "password" }` |
| `set_policy` | write | password policy presets / custom |

## Mutator JSON replies

With `--json` (and all LuCI mutator calls), denials and failures print a structured object on stdout and exit non-zero:

```json
{ "ok": false, "error": "last_admin" }
```

The `error` field is the CLI token after the `error: ` prefix (no passwords). rpcd always returns that object as the ubus reply (CLI exit status is not treated as an RPC failure). LuCI notifications show `Failed: <error>`.

Passwords on `--password-fd` / LuCI must be **single-line**. Values containing an embedded (or trailing) newline or any control character are rejected with an explicit `password_policy:multi_line` / `password_policy:control_char` (CLI) or `password_control_chars` (rpcd) error — they are never silently truncated.

Success shapes match [api-shapes.json](../prototype/api-shapes.json) (`ok: true` plus name/role as applicable).

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
- Password policy: the factory default is the **OpenWrt** preset. This preset sets a minimum of 8 characters. The password must not equal the username. Stricter presets (**Standard**, **Strict**) and individual toggles apply only after an operator saves a new policy. See [roles-and-acl](../user/roles-and-acl.md).

## Prototypes

See [docs/prototype/api-shapes.json](../prototype/api-shapes.json) and [prototypes/cli-help.txt](../../prototypes/cli-help.txt).
