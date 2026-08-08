# GitHub publish checklist

## One-time setup

- [ ] Public repo `lucas-albers-lz4/usrmanage`
- [ ] Public repo `lucas-albers-lz4/usrmanage-packages` with Pages from `gh-pages`
- [ ] Deploy key (write) on packages repo → secret `FEED_DEPLOY_KEY` on **usrmanage**
- [ ] Generate keys:

```sh
usign -G -s opkg-secret.key -p public.key -c "usrmanage opkg feed"
openssl genrsa -out apk-secret.rsa 4096
openssl rsa -in apk-secret.rsa -pubout -out usrmanage-feed.rsa.pub
```

- [ ] Secrets on **usrmanage**: `OPKG_FEED_SECRET_KEY`, `OPKG_FEED_PUBLIC_KEY`, `APK_FEED_SECRET_KEY`, `APK_FEED_PUBLIC_KEY`
- [ ] Settings → Actions → Workflow permissions: Read and write
- [ ] Do **not** commit private keys (see `.gitignore`)

## Pre-release

- [ ] `./scripts/smoke-host.sh`
- [ ] Theme + i18n tests green
- [ ] `PKG_MAINTAINER` / Apache-2.0 SPDX present
- [ ] Docs link binary feed URL

## After tag

- [ ] Workflow green
- [ ] Pages shows `24.10/`, `25.12/all/` (historical `23.05/` may remain)
- [ ] Release assets present for both packages
