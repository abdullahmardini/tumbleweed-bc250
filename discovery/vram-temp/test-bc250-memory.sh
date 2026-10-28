#!/usr/bin/env bash
#
# test-bc250-memory.sh - one-shot test of the Hexxeh bc250_memory KMP on this board.
#
# ============================= READ THIS FIRST ==============================
# HANG RISK. This module reads GDDR6 temperature by sending AMD SMU "Queue 3"
# messages through the PCI config-space index/data pair 0xB8/0xBC on 00:00.0.
# That pair is SHARED with the GPU governor (cyan-skillfish-governor-smu) and
# the CPU overclock tool, and it is not atomic. The module takes NO lock on it
# (verified: bc250_smu.c uses bare pci_{read,write}_config_dword). If anything
# else drives the SMU while this module does, the interleaved writes land in
# the wrong registers, the SMU firmware can be handed a bad chip index and wait
# forever, and the board can lock up hard (power-cycle only). Community reports
# attribute hung boards to exactly this: a second sampler, or a sample taken
# while the governor is sending its startup messages on Queue 3.
#
# This board runs STOCK P3.00 firmware (no SMU-unlock BIOS mod). The module
# cannot open the SMU debug gate itself (it only probes it: bc250_smu_patch.c
# bc250_smu_is_unlocked() -> msg 0x2A -> 0xFD -> "BIOS unlock required"). So the
# EXPECTED result of this test is that the patch does NOT install and no hwmon
# device appears. The test still sends two Queue 3 probe messages (msg 5 and
# msg 0x2A) to the STOCK firmware handlers; that is the residual risk, which is
# why the script refuses to run unless the governor is settled (its Queue 3
# traffic is confined to its first few seconds after start).
#
# This script does NOT stop the GPU governor. Rationale: project policy forbids
# stopping/starting cyan-skillfish-governor-smu.service, and stopping it is
# itself an SMU operation (its shutdown unforces gfx clock/vid on Queue 0). A
# settled governor leaves Queue 3 idle, which is what this test needs; so the
# safer move is to require "settled", not to toggle the service.
#
# Powering the board off completely is the only guaranteed way to undo an SMU
# patch or recover a wedged SMU. Run this only when you can power-cycle.
# ============================================================================

set -euo pipefail

# ------------------------------- constants ---------------------------------
readonly MODULE_NAME="bc250_memory"
KO_DEFAULT="/usr/lib/modules/$(uname -r)/updates/${MODULE_NAME}.ko"
readonly KO_DEFAULT
# auto_patch=1 is required to answer "does it work on stock P3.00?"; with
# auto_patch=0 the module loads inert and never touches the SMU.
readonly MODULE_PARAMS="auto_patch=1"
readonly GOVERNOR_UNIT="cyan-skillfish-governor-smu.service"
# The governor sends its Queue 3 startup messages within this window of its
# ExecMainStartTimestamp; sampling before it elapses can mix the two messages.
readonly GOVERNOR_SETTLE_SECONDS=5
readonly EXPECTED_BOARD="AMD BC-250"
readonly READ_COUNT=10
readonly READ_INTERVAL_SECONDS=2
readonly HWMON_ROOT="/sys/class/hwmon"
readonly DMESG_MARK="bc250-memory-test-$$"

# ------------------------------- helpers -----------------------------------
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[*] %s\n' "$*"; }

module_loaded() { [[ -d "/sys/module/${MODULE_NAME}" ]]; }

# Restore state no matter how we exit: unload the module if we loaded it.
LOADED_BY_US=0
cleanup() {
	local rc=$?
	if [[ "${LOADED_BY_US}" -eq 1 ]] && module_loaded; then
		info "unloading ${MODULE_NAME}"
		# rmmod only tears down our platform device; it sends no SMU messages.
		rmmod "${MODULE_NAME}" || printf 'WARNING: rmmod failed; module still loaded\n' >&2
	fi
	exit "${rc}"
}
trap cleanup EXIT INT TERM

# --------------------------- preconditions ---------------------------------
[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)."

KO_PATH="${1:-${KO_DEFAULT}}"
[[ -f "${KO_PATH}" ]] || die "module not found: ${KO_PATH} (install the RPM, or pass the .ko path as \$1)."

board="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
[[ "${board}" == "${EXPECTED_BOARD}" ]] || die "board_name is '${board}', expected '${EXPECTED_BOARD}'."

if module_loaded; then
	die "${MODULE_NAME} is already loaded; another session may own the SMU. Aborting."
fi

# Refuse unless the governor is active and has been running past its settle
# window. If it is restarting (fix-metrics failing), Queue 3 is hot: abort.
active_state="$(systemctl show -p ActiveState --value "${GOVERNOR_UNIT}" 2>/dev/null || true)"
sub_state="$(systemctl show -p SubState --value "${GOVERNOR_UNIT}" 2>/dev/null || true)"
start_mono="$(systemctl show -p ExecMainStartTimestampMonotonic --value "${GOVERNOR_UNIT}" 2>/dev/null || echo 0)"
if [[ "${active_state}" == "active" ]]; then
	now_mono_ns="$(awk '{printf "%d", $1 * 1000000000}' /proc/uptime)"
	start_ns=$(( start_mono * 1000 ))
	elapsed=$(( (now_mono_ns - start_ns) / 1000000000 ))
	[[ "${sub_state}" == "running" ]] || die "governor SubState is '${sub_state}', not 'running'; its Queue 3 may be active. Aborting."
	[[ "${elapsed}" -ge "${GOVERNOR_SETTLE_SECONDS}" ]] || die "governor started ${elapsed}s ago (< ${GOVERNOR_SETTLE_SECONDS}s settle). Wait and retry."
	info "governor settled (${elapsed}s since start)."
elif [[ -z "${active_state}" || "${active_state}" == "inactive" || "${active_state}" == "failed" ]]; then
	info "governor is '${active_state:-absent}'; nothing else should be driving the SMU. Proceeding."
else
	die "governor ActiveState is '${active_state}' (transient). Aborting."
fi

# ------------------------------- the test ----------------------------------
info "marking dmesg"
printf '%s\n' "${DMESG_MARK}" >/dev/kmsg || true

info "loading ${KO_PATH} ${MODULE_PARAMS}"
insmod "${KO_PATH}" ${MODULE_PARAMS}
LOADED_BY_US=1

info "kernel messages from this load:"
dmesg | sed -n "/${DMESG_MARK}/,\$p" | grep -i "${MODULE_NAME}\|SMU\|BIOS unlock\|payload" || true

# Find our hwmon device, if the patch actually installed.
hwmon_dir=""
for d in "${HWMON_ROOT}"/hwmon*; do
	[[ -r "${d}/name" ]] || continue
	if [[ "$(cat "${d}/name")" == "${MODULE_NAME}" ]]; then hwmon_dir="${d}"; break; fi
done

if [[ -z "${hwmon_dir}" ]]; then
	info "no ${MODULE_NAME} hwmon device appeared."
	info "On stock P3.00 this is EXPECTED: the module cannot open the SMU debug"
	info "gate, so the patch did not install and no temperatures are available."
	exit 0
fi

info "hwmon device: ${hwmon_dir} - reading ${READ_COUNT} times"
for ((i = 1; i <= READ_COUNT; i++)); do
	printf '--- sample %d/%d ---\n' "${i}" "${READ_COUNT}"
	for lbl in "${hwmon_dir}"/temp*_label; do
		[[ -r "${lbl}" ]] || continue
		inp="${lbl/_label/_input}"
		name="$(cat "${lbl}")"
		milli="$(cat "${inp}" 2>/dev/null || echo '?')"
		if [[ "${milli}" =~ ^-?[0-9]+$ ]]; then
			printf '  %-14s %s C\n' "${name}:" "$(awk -v m="${milli}" 'BEGIN{printf "%.1f", m/1000}')"
		else
			printf '  %-14s (read failed)\n' "${name}:"
		fi
	done
	sleep "${READ_INTERVAL_SECONDS}"
done

info "done; unloading on exit."
