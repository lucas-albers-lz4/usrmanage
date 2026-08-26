#!/bin/sh
# Host tests: interactive CLI password prompts must not echo typed characters.
# Stock OpenWrt has no stty applet; the prompt path uses read -s (ash/bash).
# When stty exists, disabling echo must succeed or the prompt fails closed.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export USRMANAGE_ETC="$TMP/etc"
export USRMANAGE_TEST_OVERRIDES=1
mkdir -p "$USRMANAGE_ETC"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# --- static: no soft-fail stty in prompt helpers ---
if grep -E 'stty -echo.*\|\| true' "$LIB" >/dev/null 2>&1; then
	bad "usrmanage-lib.sh still soft-fails stty -echo (|| true)"
else
	ok "no stty -echo soft-fail"
fi

if grep -q 'read -s -r UM_PASSWORD_READ_HIDDEN' "$LIB"; then
	ok "read -s path present for no-stty hosts"
else
	bad "missing read -s path in um_password_read_hidden"
fi

if grep -q 'cannot disable terminal echo' "$LIB"; then
	ok "fail-closed stty error message"
else
	bad "missing fail-closed stty error message"
fi

# --- functional: PTY capture — password bytes must not appear on the wire ---
if ! command -v python3 >/dev/null 2>&1; then
	echo "skip: PTY echo test (missing host tool: python3)" >&2
	exit "$fail"
fi

export LIB TMP
if python3 <<'PY'
from __future__ import annotations

import os
import pty
import select
import shutil
import subprocess
import sys
import time

lib = os.environ["LIB"]
tmp = os.environ["TMP"]
secret = "SecretPass1"
user = "ops"


def shell_read_s_capable() -> list[str] | None:
    busybox = shutil.which("busybox")
    if busybox:
        return [busybox, "ash"]
    bash = shutil.which("bash")
    if bash:
        return [bash]
    return None


def run_pty(path_label: str, shell_cmd: list[str], path_env: str) -> tuple[int, str]:
    script = f"""set -e
. "{lib}"
um_password_capture_prompt {user}
"""
    master, slave = pty.openpty()
    env = os.environ.copy()
    env["PATH"] = path_env
    env["USRMANAGE_ETC"] = os.environ.get("USRMANAGE_ETC", "")
    env["USRMANAGE_TEST_OVERRIDES"] = "1"
    if path_label == "no-stty":
        env["USRMANAGE_TEST_FORCE_READ_S"] = "1"
    proc = subprocess.Popen(
        shell_cmd + ["-c", script],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
    )
    os.close(slave)

    def read_until(marker: str, timeout: float = 5.0) -> str:
        buf = ""
        deadline = time.monotonic() + timeout
        while marker not in buf:
            if time.monotonic() > deadline:
                raise TimeoutError(f"timeout waiting for {marker!r}")
            r, _, _ = select.select([master], [], [], 0.1)
            if not r:
                if proc.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, 4096).decode("utf-8", errors="replace")
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
        return buf

    out = read_until("New password:")
    os.write(master, (secret + "\n").encode())
    out += read_until("Confirm password:")
    os.write(master, (secret + "\n").encode())

    deadline = time.monotonic() + 3.0
    while proc.poll() is None and time.monotonic() < deadline:
        r, _, _ = select.select([master], [], [], 0.1)
        if not r:
            continue
        try:
            chunk = os.read(master, 4096).decode("utf-8", errors="replace")
        except OSError:
            break
        if not chunk:
            break
        out += chunk

    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

    echoed = secret in out
    print(f"pty:{path_label}:echoed={echoed}:rc={proc.returncode}")
    return proc.returncode, out


# Path without stty: ash/bash read -s (stock OpenWrt; host uses test hook).
read_s_shell = shell_read_s_capable()
if read_s_shell is None:
    print("skip: read -s PTY test (need busybox or bash)")
else:
    rc_no, out_no = run_pty("no-stty", read_s_shell, os.environ.get("PATH", "/usr/bin:/bin"))
    if secret in out_no:
        print("FAIL: password echoed on read -s path", file=sys.stderr)
        sys.exit(1)
    if rc_no != 0:
        print(f"FAIL: prompt failed on read -s path (rc={rc_no})", file=sys.stderr)
        print(out_no, file=sys.stderr)
        sys.exit(1)

# Path with stty: fail-closed when stty -echo fails (PTY + fake stty).
fake_bin = os.path.join(tmp, "fake-stty-bin")
os.makedirs(fake_bin, exist_ok=True)
stty_fake = os.path.join(fake_bin, "stty")
with open(stty_fake, "w", encoding="utf-8") as fh:
    fh.write("#!/bin/sh\ncase \"$1\" in -echo) exit 1 ;; echo) exit 0 ;; esac\nexit 0\n")
os.chmod(stty_fake, 0o755)
bash_path = shutil.which("bash")
if bash_path is None:
    print("skip: stty-fail PTY test (bash not on host)")
else:
    fail_shell = [bash_path]
    fail_path = f"{fake_bin}:{os.environ.get('PATH', '/usr/bin:/bin')}"
    rc_fail, out_fail = run_pty("stty-fail", fail_shell, fail_path)
    if rc_fail == 0:
        print("FAIL: prompt succeeded when stty -echo failed", file=sys.stderr)
        sys.exit(1)
    if "cannot disable terminal echo" not in out_fail:
        print("FAIL: missing fail-closed stty error", file=sys.stderr)
        print(out_fail, file=sys.stderr)
        sys.exit(1)

print("ok: PTY no-echo functional")

# EOF (EOT) after New password: must fail as read_error (not empty policy).
eof_shell = shell_read_s_capable()
if eof_shell is None:
    print("skip: EOF read_error PTY test (need busybox or bash)")
else:
    script = f"""set -e
. "{lib}"
if um_password_capture_prompt {user}; then
  echo CAPTURE_OK
  exit 0
fi
echo REASON=$UM_POL_FAIL_REASON
exit 1
"""
    master, slave = pty.openpty()
    env = os.environ.copy()
    env["USRMANAGE_ETC"] = os.environ.get("USRMANAGE_ETC", "")
    env["USRMANAGE_TEST_OVERRIDES"] = "1"
    env["USRMANAGE_TEST_FORCE_READ_S"] = "1"
    proc = subprocess.Popen(
        eof_shell + ["-c", script],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
    )
    os.close(slave)
    buf = ""
    deadline = time.monotonic() + 5.0
    while "New password:" not in buf and time.monotonic() < deadline:
        r, _, _ = select.select([master], [], [], 0.1)
        if r:
            try:
                buf += os.read(master, 4096).decode("utf-8", errors="replace")
            except OSError:
                break
    # Empty-line EOT: ash/bash read returns nonzero (EOF).
    os.write(master, b"\x04")
    deadline = time.monotonic() + 3.0
    while proc.poll() is None and time.monotonic() < deadline:
        r, _, _ = select.select([master], [], [], 0.1)
        if not r:
            continue
        try:
            buf += os.read(master, 4096).decode("utf-8", errors="replace")
        except OSError:
            break
    try:
        rc = proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        print("FAIL: EOF prompt hung", file=sys.stderr)
        sys.exit(1)
    if "CAPTURE_OK" in buf or rc == 0:
        print("FAIL: EOF prompt succeeded", file=sys.stderr)
        print(buf, file=sys.stderr)
        sys.exit(1)
    if "REASON=read_error" not in buf:
        print("FAIL: EOF did not set read_error", file=sys.stderr)
        print(buf, file=sys.stderr)
        sys.exit(1)
    print("ok: PTY EOF read_error")

# Static: no soft-success on failed read in the hidden helper.
with open(lib, encoding="utf-8") as fh:
    lib_text = fh.read()
start = lib_text.find("um_password_read_hidden()")
end = lib_text.find("\num_password_capture_prompt()", start)
chunk = lib_text[start:end]
if "|| true" in chunk:
    print("FAIL: um_password_read_hidden still soft-succeeds read", file=sys.stderr)
    sys.exit(1)
print("ok: read failures propagate")

print("ok: all PTY checks")
sys.exit(0)
PY
then
	ok "PTY functional checks"
else
	bad "PTY functional checks"
fi

exit "$fail"
