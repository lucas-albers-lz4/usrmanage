# Supported OpenWrt releases

| Release | Package format | Architectures | Status |
|---------|----------------|---------------|--------|
| 24.10 | `.ipk` (opkg) | x86-64, armsr-armv8 | Supported |
| 25.12 | `.apk` | x86-64, armsr-armv8 | Supported |
| 23.05 | `.ipk` (opkg) | x86-64, armsr-armv8 | **Deprecated** — last release **v0.1.2**; no new builds |

Point pins: **24.10.5**, **25.12.0** (see [build-matrix.md](developer/build-matrix.md)).

## 23.05 deprecation

OpenWrt 23.05 is no longer in the active SDK matrix (as of the v0.1.3 wave). Existing Pages feed artifacts under `23.05/` are left in place for operators who remain on that release; install **usrmanage / luci-app-usrmanage v0.1.2** from that directory. Newer features (shadow-free stock installs) target 24.10 and 25.12 only.
