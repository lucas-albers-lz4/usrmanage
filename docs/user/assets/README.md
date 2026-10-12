# User docs screenshots

Committed WebP gallery captures from `scripts/capture-usrmanage-screenshots.mjs` (#15).

- `usrmanage-empty.webp` — empty managed-user table and OpenWrt policy strip
- `usrmanage-policy-editor.webp` — unsaved policy editor (default remains unchanged)
- `usrmanage-add-dialog.webp` — Add user dialog with blank password fields
- `usrmanage-one-user.webp` — one documented readonly fixture, `docuser`

The capture script does not boot QEMU. It refuses unexpected managed users,
audit usernames/actors, or a non-OpenWrt saved policy. It creates `docuser`
with a random password supplied over SSH stdin, never captures a password, and
removes the fixture (including its home) in `finally`. See
[`capture-screenshots.md`](capture-screenshots.md) before refreshing assets.

Screenshots are a manual, lab-dependent artifact and are not produced by PR CI.
Never commit images showing `umadmin`, `umsmoke`, `pwflow_*`, e2e/smoke users,
or real operator/customer accounts.

```sh
npm run test:ui
```

Requires Node dependencies, Playwright Chromium, `cwebp` or `ffmpeg` with libwebp, a prepared QEMU guest
with both packages installed, an SSH path to root, and a working LuCI session.
The script uses `USRMANAGE_LUCI_URL`, `USRMANAGE_LUCI_USER`,
`USRMANAGE_LUCI_PASSWORD`, `OPENWRT_HOST`, and `OPENWRT_SSH_PORT` when set.
Never put real passwords in prompts, command arguments, screenshots, or traces.
There is no trace recording in the capture script.

See [user installation](../installation.md#user-interface-gallery).

License note: screenshots document the stock LuCI interface; product source is
Apache-2.0. Do not include real device data.

<!--- cspell:ignore cwebp docuser pwflow usrmanage -->
