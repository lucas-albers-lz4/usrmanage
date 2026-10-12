# Capturing the User Management gallery

This is a local/manual workflow against a prepared QEMU lab. It does not start
or stop QEMU. Install the dev dependencies and Playwright browser once:

```sh
npm ci
npx playwright install chromium
# Install cwebp or ffmpeg with libwebp, then boot the prepared lab separately.
npm run test:ui
```

The default LuCI URL is `http://127.0.0.1:8080`; SSH defaults to
`root@127.0.0.1:2222`. Configure the environment when using different ports or
credentials:

```sh
USRMANAGE_LUCI_URL=http://127.0.0.1:8080 \
OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 \
USRMANAGE_LUCI_USER=root USRMANAGE_LUCI_PASSWORD='' \
npm run test:ui
```

## Clean-state guard

Before opening a browser, the script checks the guest over SSH:

- The managed-user list must be empty. It will not delete or adopt unexpected
  users.
- The saved policy must still be the OpenWrt factory preset. The script never
  saves or changes policy.
- Audit users and actors must be limited to `root`, `unknown`, and the
  documented `docuser` fixture. Unexpected names stop the capture.
- No unmanaged UNIX account named `docuser` may already exist.

If a guard fails, inspect the lab manually and clean it intentionally; do not
weaken the allowlist to make a capture pass. The UI is also checked before each
screenshot so blocked smoke/e2e names cannot appear in the image.

## Captures and cleanup

The script creates four 1440×900 WebP images under this directory: empty table,
policy editor, Add dialog (blank password fields), and one readonly `docuser`
row. The demo password is freshly generated, sent to `usrmanage` only over SSH
stdin (`--password-fd 0`), and never printed or placed in argv. No screenshot is
taken while a password field is populated. The `docuser` account and home are
removed in `finally`; the initial state is checked again before publishing the
new image files.

Playwright tracing is disabled/not started. The screenshots are not created in
CI and are not proof of rendered safety; review every image before committing.
Do not commit captures containing lab/smoke/e2e users or real device data.

<!--- cspell:ignore cwebp docuser pwflow usrmanage -->
