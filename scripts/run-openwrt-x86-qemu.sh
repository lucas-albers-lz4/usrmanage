#!/usr/bin/env bash
# Run OpenWrt x86/64 disk image in QEMU (KVM when available).
#
#   OWRT_RELEASE=24.10.5 ./scripts/run-openwrt-x86-qemu.sh
#   ./scripts/run-openwrt-x86-qemu.sh --stop
#
# LuCI http://localhost:8080/cgi-bin/luci/
# SSH  ssh -p 2222 root@localhost
set -euo pipefail

if [[ "$(uname -m)" != "x86_64" ]]; then
	echo "x86_64 QEMU runner requires an x86_64 Linux host." >&2
	exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OWRT_LAB_NET_MODE="${OWRT_LAB_NET_MODE:-dhcp}"
# shellcheck source=lib/qemu-lab-net.sh
source "${ROOT}/scripts/lib/qemu-lab-net.sh"
IMG_DIR="${ROOT}/lab/images"

resolve_x86_disk() {
	if [[ -n "${OWRT_X86_IMG:-}" ]]; then echo "${OWRT_X86_IMG}"; return; fi
	if [[ -n "${OWRT_RELEASE:-}" ]]; then
		local rel_img="${IMG_DIR}/openwrt-x86-64-${OWRT_RELEASE}.img"
		[[ -f "${rel_img}" ]] && echo "${rel_img}" && return
	fi
	if [[ -f "${IMG_DIR}/openwrt-x86-64.img" ]]; then echo "${IMG_DIR}/openwrt-x86-64.img"; return; fi
	shopt -s nullglob
	local candidates=( "${IMG_DIR}"/openwrt-x86-64-*.img )
	shopt -u nullglob
	[[ ${#candidates[@]} -ge 1 ]] && echo "${candidates[0]}" && return
	echo ""
}

OWRT_IMG="$(resolve_x86_disk)"
OWRT_HOSTFWD_HTTP="${OWRT_HOSTFWD_HTTP:-8080}"
OWRT_HOSTFWD_SSH="${OWRT_HOSTFWD_SSH:-2222}"
OWRT_CONSOLE_LOG="${OWRT_CONSOLE_LOG:-${ROOT}/lab/qemu-x86-console.log}"
OWRT_QEMU_MEM="${OWRT_QEMU_MEM:-1024}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-${IMG_DIR}/OVMF_VARS_4M.fd}"
OWRT_QEMU_PIDFILE="${OWRT_QEMU_PIDFILE:-${ROOT}/lab/qemu-x86.pid}"

die() { echo "error: $*" >&2; exit 1; }

stop_qemu() {
	if [[ -f "${OWRT_QEMU_PIDFILE}" ]]; then
		local pid
		pid="$(cat "${OWRT_QEMU_PIDFILE}" 2>/dev/null || true)"
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
			sleep 1
			kill -9 "$pid" 2>/dev/null || true
			echo "Stopped QEMU pid ${pid}."
		fi
		rm -f "${OWRT_QEMU_PIDFILE}"
	fi
	if pkill -f 'qemu-system-x86_64.*openwrt-x86-64' 2>/dev/null; then
		echo "Stopped running x86 QEMU instance(s)."
	else
		echo "No x86 QEMU instance was running."
	fi
}

check_host_ports() {
	local port spec
	for spec in "${OWRT_HOSTFWD_HTTP}:HTTP" "${OWRT_HOSTFWD_SSH}:SSH"; do
		port="${spec%%:*}"
		if ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
			die "host port ${port} (${spec#*:}) already in use"
		fi
	done
}

if [[ "${1:-}" == "--stop" ]]; then
	stop_qemu
	exit 0
fi

[[ -n "${OWRT_IMG}" && -f "${OWRT_IMG}" ]] || die "No disk image under ${IMG_DIR}/"
[[ -f "${OVMF_CODE}" ]] || die "Missing OVMF firmware (${OVMF_CODE}) — install ovmf"
if [[ ! -f "${OVMF_VARS}" ]]; then
	cp /usr/share/OVMF/OVMF_VARS_4M.fd "${OVMF_VARS}"
fi

check_host_ports
mkdir -p "$(dirname "${OWRT_CONSOLE_LOG}")"
: > "${OWRT_CONSOLE_LOG}"

resolve_x86_qemu_accel() {
	if [[ -n "${OWRT_QEMU_ACCEL:-}" ]]; then
		printf '%s' "$OWRT_QEMU_ACCEL"
		return
	fi
	if [[ -r /dev/kvm && -w /dev/kvm ]]; then
		printf '%s' kvm
	else
		printf '%s' tcg
	fi
}

ACCEL="$(resolve_x86_qemu_accel)"
CPU="${OWRT_QEMU_CPU:-host}"
[[ "$ACCEL" == "tcg" ]] && CPU="${OWRT_QEMU_CPU:-max}"

NIC_USER="$(qemu_lab_nic_user "${OWRT_HOSTFWD_HTTP}" "${OWRT_HOSTFWD_SSH}")"

echo "Using disk:  ${OWRT_IMG}"
echo "Console log: ${OWRT_CONSOLE_LOG}"
echo "Accel:       ${ACCEL} (cpu ${CPU})"
echo "LuCI  http://localhost:${OWRT_HOSTFWD_HTTP}/cgi-bin/luci/"
echo "SSH   ssh -p ${OWRT_HOSTFWD_SSH} root@localhost"

QEMU_ARGS=(
	-machine q35 -accel "${ACCEL}" -cpu "${CPU}"
	-smp 2 -m "${OWRT_QEMU_MEM}"
	-display none -nographic
	-monitor none
	-drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
	-drive "if=pflash,format=raw,file=${OVMF_VARS}"
	-drive "file=${OWRT_IMG},format=raw,if=virtio"
	-nic "${NIC_USER}"
	-serial mon:stdio
)

if [[ "${OWRT_QEMU_DAEMON:-0}" == "1" ]]; then
	qemu-system-x86_64 "${QEMU_ARGS[@]}" >"${OWRT_CONSOLE_LOG}" 2>&1 &
	echo $! >"${OWRT_QEMU_PIDFILE}"
	echo "QEMU daemon pid $(cat "${OWRT_QEMU_PIDFILE}")"
	exit 0
fi

exec qemu-system-x86_64 "${QEMU_ARGS[@]}" 2>&1 | tee -a "${OWRT_CONSOLE_LOG}"
