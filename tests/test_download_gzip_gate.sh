#!/usr/bin/env bash
# Regression for download-openwrt-x86-64.sh's gzip decompression gate.
#
# The gate logic (extracted verbatim from the shipped script so this test
# cannot drift from production):
#   - output must be non-empty ([[ -s ]])
#   - gzip exit 2 is accepted ONLY with the "trailing garbage ignored"
#     warning on stderr (the real OpenWrt .img.gz case)
#   - gzip exit 0/1 accepted; any other code rejected
set -u
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/download-openwrt-x86-64.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the gate block verbatim from the shipped script: lines from the
# "Decompressing" echo through the final rc-range check (fi on line 124 —
# i.e. the second `fi` after the echo; anchors on the trailing `rm -f
# decompress.err` so extraction cannot drift).
GATE="$(sed -n '/^echo "Decompressing/,/^rm -f "\${OUT}\/decompress.err"$/p' "$SRC")"
[[ -n "$GATE" ]] || { echo "FAIL: could not extract gate from $SRC" >&2; exit 1; }

# Gate harness: supplies OUT, IMG_GZ, IMG_OUT, and a fake gzip that writes
# nonempty output and exits with the requested code/stderr message.
# $1 = gzip exit code, $2 = stderr line, $3 = output size ("full"|"empty")
run_gate() {
	local gz_exit="$1" gz_err="$2" out_size="${3:-full}"
	local work="$TMP/work-$RANDOM"
	mkdir -p "$work"
	: > "$work/img.gz"
	: > "$work/img.out"
	local rc
	(
		cd "$work"
		cat > gzip <<'FG'
#!/usr/bin/env bash
# Fake gzip used by the gate: emit decompressed bytes on stdout (unless
# FAKE_GZIP_EMPTY), the configured stderr message, and exit with the
# configured code.
[[ "${FAKE_GZIP_EMPTY:-0}" != "1" ]] && echo "fake-decompressed-bytes"
printf '%s' "${FAKE_GZIP_ERR:-}" >&2
exit "${FAKE_GZIP_EXIT:-0}"
FG
		chmod +x gzip
		export FAKE_GZIP_EXIT="$gz_exit" FAKE_GZIP_ERR="$gz_err"
		export FAKE_GZIP_EMPTY=0
		[[ "$out_size" == "empty" ]] && export FAKE_GZIP_EMPTY=1
		# The gate references gzip, OUT, IMG_GZ, IMG_OUT — run it with our
		# fake gzip on PATH and the gate's own variables.
		PATH="$work:$PATH" OUT="$work" IMG_GZ="img.gz" IMG_OUT="img.out" \
			bash -c "$GATE" >/dev/null 2>&1
	)
	rc=$?
	rm -rf "$work"
	return "$rc"
}

# 1. exit 2 + trailing-garbage warning → accepted (the real OpenWrt case)
if run_gate 2 "gzip: img.gz: decompression OK, trailing garbage ignored"; then
	ok "gzip exit 2 with trailing-garbage warning accepted"
else
	bad "gzip exit 2 with trailing-garbage warning must be accepted (real image case)"
fi

# 2. exit 2 WITHOUT the warning → rejected (fatal, nonempty partial output)
if run_gate 2 "gzip: img.gz: invalid compressed data--format violated"; then
	bad "gzip exit 2 without warning must be rejected"
else
	ok "gzip exit 2 without warning rejected"
fi

# 3. exit 0 → accepted
if run_gate 0 ""; then
	ok "gzip exit 0 accepted"
else
	bad "gzip exit 0 must be accepted"
fi

# 4. exit 3 → rejected (unexpected code)
if run_gate 3 "gzip: something else"; then
	bad "gzip exit 3 must be rejected"
else
	ok "gzip exit 3 rejected"
fi

# 5. exit 2 + warning but EMPTY output → rejected (size guard)
if run_gate 2 "gzip: img.gz: decompression OK, trailing garbage ignored" empty; then
	bad "empty output must be rejected by [[ -s ]]"
else
	ok "empty output rejected"
fi

[[ "$fail" -eq 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "FAILURES" >&2; exit 1; }
