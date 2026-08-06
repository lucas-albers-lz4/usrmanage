# Release process

1. Ensure `./scripts/smoke-host.sh` passes locally.
2. Bump `PKG_VERSION` / `LUCI` package versions if needed in both Makefiles.
3. Commit and push to `main`.
4. Create annotated tag:

```sh
git tag -a v0.1.0 -m "usrmanage 0.1.0"
git push origin v0.1.0
```

5. GitHub Actions `publish-packages`:
   - Builds 23.05 / 24.10 / 25.12 × x86-64 + armsr-armv8
   - Reproducible double-build on x86-64
   - Signs and deploys feed to `usrmanage-packages`
   - Attaches `.ipk` / `.apk` to the GitHub Release
6. Verify Pages indexes and install on a lab device (`usrmanage doctor`).

Manual re-run: Actions → publish-packages → workflow_dispatch with tag name.

See [github-publish-checklist.md](github-publish-checklist.md) and [binary-feed.md](binary-feed.md).
