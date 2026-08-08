#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Host-side Z3 checks for usrmanage regex/case sanitation (#6 / #8).

Mirrors um_validate_username / um_actor_resolve / um_audit_token alphabets
from usrmanage-lib.sh. Not a full re-implementation of BusyBox ash `case`
glob semantics — properties below are alphabet + length + denylist gates.

Usage:
  ./scripts/z3-verify.py --fast
  ./scripts/z3-verify.py --full
"""
from __future__ import annotations

import argparse
import sys

try:
	from z3 import And, Bool, Exists, If, Int, Or, Solver, String, StringVal, sat, unsat
	from z3 import Length, SubString, Unit, seq  # noqa: F401
except ImportError:  # pragma: no cover
	print("error: z3 python module missing (apt: python3-z3 or pip install z3-solver)", file=sys.stderr)
	sys.exit(2)

DENY = ("root", "daemon", "ftp", "network", "nobody", "nogroup", "admin", "ubus", "sync")
USER_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_-"
ACTOR_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._@-"


def _char_in(s, i, alphabet: str):
	return Or(*[SubString(s, i, 1) == StringVal(c) for c in alphabet])


def username_ok(s):
	"""Z3 predicate approximating um_validate_username."""
	n = Length(s)
	conds = [n >= 1, n <= 32]
	# leading letter or underscore (simplified: first char in a-z_)
	conds.append(Or(*[SubString(s, 0, 1) == StringVal(c) for c in "abcdefghijklmnopqrstuvwxyz_"]))
	# not starting with digit or hyphen already covered by leading set
	# all chars in USER_CHARS — bound length for quantifier-free encoding
	for i in range(32):
		conds.append(If(n > i, _char_in(s, i, USER_CHARS), True))
	for d in DENY:
		conds.append(s != StringVal(d))
	return And(*conds)


def actor_ok(s):
	n = Length(s)
	conds = [n >= 1, n <= 64]
	for i in range(64):
		conds.append(If(n > i, _char_in(s, i, ACTOR_CHARS), True))
	# forbid empty already; block space/= via alphabet
	return And(*conds)


def check_unsat(name: str, formula) -> bool:
	sol = Solver()
	sol.add(formula)
	r = sol.check()
	if r == unsat:
		print(f"ok: {name}")
		return True
	if r == sat:
		print(f"FAIL: {name} — unexpected model: {sol.model()}", file=sys.stderr)
		return False
	print(f"FAIL: {name} — solver {r}", file=sys.stderr)
	return False


def check_sat(name: str, formula) -> bool:
	sol = Solver()
	sol.add(formula)
	r = sol.check()
	if r == sat:
		print(f"ok: {name}")
		return True
	print(f"FAIL: {name} — expected sat got {r}", file=sys.stderr)
	return False


def run_fast() -> int:
	fail = 0
	u = String("u")
	# P1: empty rejected
	if not check_unsat("P1 empty rejected", And(u == StringVal(""), username_ok(u))):
		fail += 1
	# P1: leading digit rejected
	if not check_unsat("P1 leading digit rejected", And(SubString(u, 0, 1) == StringVal("1"), username_ok(u))):
		fail += 1
	# P1: space rejected
	if not check_unsat("P1 space rejected", And(u == StringVal("bad name"), username_ok(u))):
		fail += 1
	# P1: deny root
	if not check_unsat("P1 deny root", And(u == StringVal("root"), username_ok(u))):
		fail += 1
	# P1: good example sat
	if not check_sat("P1 ops accepted", And(u == StringVal("ops"), username_ok(u))):
		fail += 1
	# P1: length 33 rejected
	long33 = StringVal("a" * 33)
	if not check_unsat("P1 len>32 rejected", And(u == long33, username_ok(u))):
		fail += 1
	# P2 alphabet: actor cannot contain '='
	a = String("a")
	if not check_unsat("P2 actor forbids '='", And(a == StringVal("x=y"), actor_ok(a))):
		fail += 1
	if not check_sat("P2 actor accepts root-like", And(a == StringVal("root"), actor_ok(a))):
		fail += 1
	return fail


def run_full() -> int:
	fail = run_fast()
	u = String("u")
	# Additional deny-list members
	for d in DENY:
		if not check_unsat(f"P1 deny {d}", And(u == StringVal(d), username_ok(u))):
			fail += 1
	# Uppercase rejected
	if not check_unsat("P1 uppercase rejected", And(u == StringVal("Ops"), username_ok(u))):
		fail += 1
	# Leading hyphen rejected
	if not check_unsat("P1 leading hyphen rejected", And(u == StringVal("-ab"), username_ok(u))):
		fail += 1
	# Valid underscore start
	if not check_sat("P1 underscore start", And(u == StringVal("_svc"), username_ok(u))):
		fail += 1
	return fail


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__)
	g = ap.add_mutually_exclusive_group()
	g.add_argument("--fast", action="store_true", help="pre-commit subset")
	g.add_argument("--full", action="store_true", help="CI / full suite (default)")
	args = ap.parse_args()
	mode_full = not args.fast
	fail = run_full() if mode_full else run_fast()
	if fail:
		print(f"z3-verify: {fail} failure(s)", file=sys.stderr)
		return 1
	print("z3-verify: ok")
	return 0


if __name__ == "__main__":
	sys.exit(main())
