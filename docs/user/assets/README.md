# User docs screenshots

WebP captures from `scripts/capture-usrmanage-screenshots.mjs` (#15).

**Hard requirement:** managed-user table must be empty (or only documented fixture names). Never commit shots showing `umadmin`, `pwflow_*`, or smoke/matrix leftovers.

```sh
# lab up with luci-app-usrmanage
./scripts/capture-usrmanage-screenshots.mjs
```
