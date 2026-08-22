#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""CI contract: advertised diagnostic LuCI pages vs ACL-granted ubus methods.

Readonly owned LuCI grants stock ACL *group names* (status-routes, network-config,
…). Stock page JS still calls ubus methods that often live only under luci-base /
luci-base-network-status — which we must not grant. That mismatch ships broken
menus (#156).

This test unions ubus read grants from:
  - tests/fixtures/luci-acl/*.json for groups on the diagnostic read set
  - openwrt-feed/luci-app-usrmanage/.../luci-app-usrmanage.json

Required methods come from diagnostic-page-rpc-required.tsv.
Gaps must exactly match diagnostic-page-rpc-known-gaps.tsv.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / "tests" / "fixtures"
ACL_DIR = FIX / "luci-acl"
REQUIRED = FIX / "diagnostic-page-rpc-required.tsv"
KNOWN_GAPS = FIX / "diagnostic-page-rpc-known-gaps.tsv"
OUR_ACL = (
	ROOT
	/ "openwrt-feed"
	/ "luci-app-usrmanage"
	/ "root"
	/ "usr"
	/ "share"
	/ "rpcd"
	/ "acl.d"
	/ "luci-app-usrmanage.json"
)

# Must stay aligned with um_luci_login_expected_reads(readonly) / docs.
DIAGNOSTIC_GROUPS = (
	"luci-app-usrmanage-session",
	"luci-app-usrmanage-health",
	"luci-app-usrmanage",
	"luci-app-usrmanage-diagnostic-rpc",
	"luci-mod-status-index",
	"luci-mod-status-routes",
	"luci-mod-status-realtime",
	"luci-mod-network-config",
	"luci-mod-network-diagnostics",
)

STOCK_FILES = (
	"luci-base.json",
	"luci-mod-status.json",
	"luci-mod-status-index.json",
	"luci-mod-network.json",
)


def load_tsv(path: Path) -> set[tuple[str, str, str]]:
	rows: set[tuple[str, str, str]] = set()
	for line in path.read_text(encoding="utf-8").splitlines():
		line = line.strip()
		if not line or line.startswith("#"):
			continue
		parts = line.split("\t")
		if len(parts) != 3:
			raise SystemExit(f"bad TSV row in {path}: {line!r}")
		rows.add((parts[0], parts[1], parts[2]))
	return rows


def collect_ubus_reads(acl_blob: dict, groups: set[str]) -> set[tuple[str, str]]:
	"""Return {(object, method)} granted on read.ubus for selected groups."""
	out: set[tuple[str, str]] = set()
	for name, spec in acl_blob.items():
		if name not in groups:
			continue
		if not isinstance(spec, dict):
			continue
		read = spec.get("read") or {}
		ubus = read.get("ubus") or {}
		if not isinstance(ubus, dict):
			continue
		for obj, methods in ubus.items():
			if not isinstance(methods, list):
				continue
			for m in methods:
				out.add((str(obj), str(m)))
	return out


def main() -> int:
	groups = set(DIAGNOSTIC_GROUPS)
	granted: set[tuple[str, str]] = set()

	for fname in STOCK_FILES:
		path = ACL_DIR / fname
		if not path.is_file():
			print(f"missing stock ACL fixture: {path}", file=sys.stderr)
			return 1
		granted |= collect_ubus_reads(json.loads(path.read_text(encoding="utf-8")), groups)

	if not OUR_ACL.is_file():
		print(f"missing our ACL: {OUR_ACL}", file=sys.stderr)
		return 1
	granted |= collect_ubus_reads(json.loads(OUR_ACL.read_text(encoding="utf-8")), groups)

	required = load_tsv(REQUIRED)
	known = load_tsv(KNOWN_GAPS)

	gaps: set[tuple[str, str, str]] = set()
	for page, obj, method in sorted(required):
		if (obj, method) not in granted:
			gaps.add((page, obj, method))

	unexpected_known = known - gaps
	unlisted_gaps = gaps - known

	print("diagnostic ubus grants (object.method):")
	for obj, method in sorted(granted):
		print(f"  {obj}.{method}")

	print(
		f"required page RPCs: {len(required)}; gaps: {len(gaps)}; "
		f"known-gap allowlist: {len(known)}"
	)

	rc = 0
	if unlisted_gaps:
		rc = 1
		print(
			"NEW diagnostic page RPC gaps (add to known-gaps or fix ACLs) [#156]:",
			file=sys.stderr,
		)
		for page, obj, method in sorted(unlisted_gaps):
			print(f"  {page}\t{obj}\t{method}", file=sys.stderr)

	if unexpected_known:
		rc = 1
		print(
			"STALE known-gaps (RPC now granted — remove from allowlist):",
			file=sys.stderr,
		)
		for page, obj, method in sorted(unexpected_known):
			print(f"  {page}\t{obj}\t{method}", file=sys.stderr)

	if "luci-base" in groups or "luci-base-network-status" in groups:
		print("diagnostic group list must not include luci-base*", file=sys.stderr)
		rc = 1

	our = json.loads(OUR_ACL.read_text(encoding="utf-8"))
	sess = ((our.get("luci-app-usrmanage-session") or {}).get("read") or {}).get("ubus") or {}
	if "uci" in sess:
		print(
			"session ACL must not grant ubus uci (use a dedicated narrow ACL)",
			file=sys.stderr,
		)
		rc = 1

	if rc == 0:
		if gaps:
			print(f"ok: {len(gaps)} known diagnostic RPC gap(s) tracked (#156)")
		else:
			print("ok: all advertised diagnostic page RPCs covered by ACL union")
	return rc


if __name__ == "__main__":
	sys.exit(main())
