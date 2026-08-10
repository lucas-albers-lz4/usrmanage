# Security Policy

## Supported Versions

Security fixes are applied to the latest release on `main` for currently
supported OpenWrt targets (24.10 / 25.12). OpenWrt 23.05 remains on the last published v0.1.2 feed.

## Reporting a Vulnerability

Please **do not** open a public issue for security reports.

Use GitHub's private vulnerability reporting for this repository
(**Security → Report a vulnerability**), or email the maintainer via the
address on the GitHub profile.

We aim to acknowledge reports within a few business days and will coordinate
a fix and disclosure timeline with you.

## Documentation for reviewers

- [docs/security-review.md](docs/security-review.md) — audit ledger: surface coverage map, controls in force, open findings, review procedure. Start here.
- [docs/threat-model.md](docs/threat-model.md) — assets, actors, abuse cases (runtime and supply chain)
- [docs/security.md](docs/security.md) — operator / deployment guidance

Already-public hardening work is tracked under the [`security` label](https://github.com/lucas-albers-lz4/usrmanage/labels/security). Undisclosed vulnerabilities go through private reporting above, not that label.
