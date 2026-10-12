#!/usr/bin/env bash
# Structural guards for the #15 WebP gallery (assets + capture script).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/capture-usrmanage-screenshots.mjs"
ASSETS="$ROOT/docs/user/assets"
PKG="$ROOT/package.json"
GITIGNORE="$ROOT/.gitignore"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SRC" ]] || fail "missing capture script"
grep -q 'usrmanage-empty.webp' "$SRC" || fail "capture script missing empty shot"
grep -q 'usrmanage-add-dialog.webp' "$SRC" || fail "capture script missing add-dialog shot"
grep -q 'usrmanage-policy-editor.webp' "$SRC" || fail "capture script missing policy-editor shot"
grep -q 'usrmanage-one-user.webp' "$SRC" || fail "capture script missing one-user shot"
grep -q 'umadmin' "$SRC" || fail "capture script missing umadmin stray marker"
grep -q 'pwflow_' "$SRC" || fail "capture script missing pwflow_ stray marker"
grep -q 'libwebp' "$SRC" || fail "WebP encode must use ffmpeg libwebp (Playwright 1.60 has no webp type)"
grep -q 'password-fd' "$SRC" || fail "fixture add must use --password-fd"
grep -q 'Leave password fields empty' "$SRC" || fail "add-dialog must not type passwords"
grep -q 'hideLabNags' "$SRC" || fail "lab root-password nag must be stripped from shots"
grep -q 'capture-guest-reset.sh' "$SRC" || fail "capture script must use the guest reset helper"
[[ -f "$ROOT/scripts/lib/capture-guest-reset.sh" ]] || fail "missing guest reset helper"
grep -q 'lab_unwind' "$ROOT/scripts/lib/capture-guest-reset.sh" || fail "guest reset missing last_admin unwind"
grep -q 'usrmanage list failed' "$ROOT/scripts/lib/capture-guest-reset.sh" || fail "guest reset must fail closed if list fails"
grep -q 'incomplete' "$ROOT/scripts/lib/capture-guest-reset.sh" || fail "guest reset must clear leftover incomplete marker"

grep -q '"test:ui"' "$PKG" || fail "package.json missing test:ui"
grep -q 'capture-usrmanage-screenshots.mjs' "$PKG" || fail "test:ui must run the capture script"

grep -q 'usrmanage-debug.webp' "$GITIGNORE" || fail "debug screenshot must be gitignored"

for f in usrmanage-empty.webp usrmanage-add-dialog.webp usrmanage-policy-editor.webp usrmanage-one-user.webp; do
	[[ -s "$ASSETS/$f" ]] || fail "missing or empty gallery asset $f"
done
if git -C "$ROOT" ls-files --error-unmatch docs/user/assets/usrmanage-debug.webp >/dev/null 2>&1; then
	fail "debug screenshot must not be committed"
fi

echo "docs screenshot contract tests passed (static only)"
