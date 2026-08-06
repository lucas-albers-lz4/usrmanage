# OpenWrt feed: usrmanage

Packages in this feed:

| Package | Role |
|---------|------|
| `usrmanage` | CLI + library + sudoers + registry |
| `luci-app-usrmanage` | LuCI UI + rpcd plugin + ACL |

## Wire the feed

```sh
echo "src-link usrmanage /absolute/path/to/usrmanage/openwrt-feed" >> feeds.conf
./scripts/feeds update usrmanage
./scripts/feeds install usrmanage luci-app-usrmanage
```

Template: [`../feeds.conf.example`](../feeds.conf.example)

Use **`src-link`** to `openwrt-feed/`, not the repo root.

Enable in menuconfig:

- **Administration → usrmanage**
- **LuCI → Applications → luci-app-usrmanage**
