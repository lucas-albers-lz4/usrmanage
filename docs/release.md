# Release process

## Versioning

Bump the **third octet** of `PKG_VERSION` for every publishable build (same approach as fwlive):

- `0.1.0` → `0.1.1` → `0.1.2`
- Keep `PKG_RELEASE:=1` unless you need an OpenWrt-only rebuild of the same upstream version
- Set the same `PKG_VERSION` / `PKG_RELEASE` in both `openwrt-feed/usrmanage/Makefile` and `openwrt-feed/luci-app-usrmanage/Makefile`
- Git tag matches `PKG_VERSION`: `v0.1.1` (do not use `v0.1.0-r2`-style tags)

## Steps

1. Ensure `./scripts/smoke-host.sh` passes locally.
2. Bump `PKG_VERSION` (third octet) in both Makefiles as above.
3. Commit and push to `main`.
4. Create annotated tag:

```sh
git tag -a v0.1.1 -m "usrmanage 0.1.1"
git push origin v0.1.1
```

5. GitHub Actions `publish-packages` (Environment **`feed-publish`** — configure required
   reviewers in repo Settings → Environments before the first publish after this change):
   - Builds 24.10 / 25.12 × x86-64 + armsr-armv8
   - Reproducible double-build on x86-64
   - Signs and deploys feed to `usrmanage-packages`
   - Attaches `.ipk` / `.apk` to the GitHub Release
6. Verify Pages indexes and install on a lab device (`usrmanage doctor`).

Manual re-run: Actions → publish-packages → workflow_dispatch with a **tag name** matching
`^v[0-9]` (e.g. `v0.1.5`). Checkout uses `persist-credentials: false` so the job token is
not present in the SDK bind mount.

See [github-publish-checklist.md](github-publish-checklist.md) and [binary-feed.md](binary-feed.md).
Before cutting a `v*` tag, re-verify the `peaceiris/actions-gh-pages` SHA in
`publish-packages.yml` against the upstream tag (checklist pre-release item).
