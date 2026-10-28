#!/usr/bin/env bash
# aspm-probe.sh - BC-250 PCIe ASPM evidence capture and one-link L1 A/B test.
#
# Usage (as root):
#   sudo bash aspm-probe.sh evidence            # read-only: lspci, latency math, FADT, _OSC, sysfs
#   sudo bash aspm-probe.sh toggle 0000:04:00.0 # flip l1_aspm on ONE link, measure, then restore
#
# "toggle" writes the opposite of the current l1_aspm value (NIC 0 -> 1, NVMe 1 -> 0),
# measures PPT + turbostat before and after a settle period, watches AER and the
# kernel log, and ALWAYS writes the original value back on exit (trap), including
# Ctrl-C, SIGTERM and SIGHUP (SSH drop). Run "toggle" from a local console or under
# `systemd-run --scope` / tmux if you are on SSH over the NIC.
set -euo pipefail

# Output holds lspci dumps with device serials: keep it out of the repo.
readonly OUT_ROOT="${BC250_ASPM_OUT:-/var/tmp/bc250-aspm}"
readonly SYS_PCI="/sys/bus/pci/devices"
readonly POLICY_FILE="/sys/module/pcie_aspm/parameters/policy"
readonly FACP_TABLE="/sys/firmware/acpi/tables/FACP"
# FADT IAPC_BOOT_ARCH: 2-byte field at byte offset 109 (0x6D) of the FACP table (ACPI spec 5.2.9).
readonly FADT_IAPC_BOOT_ARCH_OFFSET=109
# Bit 4 of IAPC_BOOT_ARCH = "PCIe ASPM Controls": set means the OS must NOT enable ASPM.
readonly FADT_NO_ASPM_BIT=4
# amdgpu hwmon PPT (whole APU, microwatts). Board-side NVMe/NIC power is NOT in PPT.
# Reached through the GPU device: hwmon numbering shifts with module load order.
PPT_FILE=$(echo /sys/bus/pci/devices/0000:01:00.0/hwmon/hwmon*/power1_average)
readonly PPT_FILE
readonly PPT_SAMPLES=30          # one sample per second
readonly PPT_SAMPLE_INTERVAL_S=1
# Time after the write before measuring, so idle PM (and the link) reach steady state.
readonly SETTLE_SECONDS=60
readonly NVME_READ_MIB=256       # read-only O_DIRECT read to prove the NVMe link still works
readonly PING_COUNT=10
# Links to report: "root_port endpoint" pairs (from lspci -t on this board).
readonly LINK_PAIRS=(
	"0000:00:08.1 0000:01:00.0"
	"0000:00:08.1 0000:01:00.1"
	"0000:00:08.1 0000:01:00.2"
	"0000:00:15.0 0000:03:00.0"
	"0000:00:15.1 0000:04:00.0"
)
# Only these endpoints may be toggled. The GPU link (00:08.1 -> 01:00.x) is on-die;
# a hang there takes the display and the governor with it, so it is excluded.
readonly TOGGLE_ALLOWED=("0000:03:00.0" "0000:04:00.0")

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo bash $0 ...)"

OUT_DIR="$OUT_ROOT/out-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
echo "Output: $OUT_DIR"

# lspci latency string -> nanoseconds. "unlimited" (DevCap acceptable, encoding 7)
# means no limit; ">64us" (LnkCap exit, encoding 7) is treated as 65us like the kernel.
lat_to_ns() {
	local s=$1
	case $s in
		unlimited) echo "inf" ;;
		'<'*us) echo $(( ${s//[<us]/} * 1000 )) ;;
		'<'*ns) echo "${s//[<ns]/}" ;;
		'>64us') echo 65000 ;;
		*) die "unparsed latency '$s'" ;;
	esac
}

# Print one field from `lspci -vvv -s DEV` (full output passed on stdin).
# awk reads all input: grep -m1 quits early, lspci gets SIGPIPE and pipefail kills the script.
lspci_line() { awk -v pat="^[[:space:]]+$1" '!found && $0 ~ pat { print; found = 1 }'; }

link_report() {
	local up=$1 ep=$2 up_txt ep_txt up_lnkcap ep_lnkcap ep_devcap up_l1 ep_l1 acc_l1 worst
	up_txt=$(lspci -vvv -s "$up")
	ep_txt=$(lspci -vvv -s "$ep")
	echo "=== link $up -> $ep"
	for dev in "$up" "$ep"; do
		local t
		t=$([[ $dev == "$up" ]] && echo "$up_txt" || echo "$ep_txt")
		echo "--- $dev"
		for f in 'DevCap:' 'LnkCap:' 'LnkCtl:' 'LnkSta:' 'DevCap2:' 'DevCtl2:' 'L1SubCap:' 'L1SubCtl1:' 'Max snoop latency'; do
			echo "$t" | lspci_line "$f"
		done
		echo "$t" | grep -q 'L1 PM Substates' || echo "    (no L1 PM Substates capability)"
	done
	up_lnkcap=$(echo "$up_txt" | lspci_line 'LnkCap:')
	ep_lnkcap=$(echo "$ep_txt" | lspci_line 'LnkCap:')
	ep_devcap=$(echo "$ep_txt" | lspci_line 'DevCap:')
	# Exit latency is the "L1 x" after "Exit Latency"; acceptable latency is the "L1 x" in DevCap.
	up_l1=$(grep -oE 'L1 (unlimited|[<>][0-9]+[un]s)' <<<"${up_lnkcap#*Exit Latency}" | awk '{print $2}' | tail -n1)
	ep_l1=$(grep -oE 'L1 (unlimited|[<>][0-9]+[un]s)' <<<"${ep_lnkcap#*Exit Latency}" | awk '{print $2}' | tail -n1)
	acc_l1=$(grep -oE 'L1 (unlimited|[<>][0-9]+[un]s)' <<<"$ep_devcap" | awk '{print $2}' | tail -n1)
	if [[ -z $up_l1 || -z $ep_l1 || -z $acc_l1 ]]; then
		echo "LATENCY: could not parse (up='$up_l1' ep='$ep_l1' acceptable='$acc_l1')"
		return 0
	fi
	# Directly attached to a root port: no switch hops, so path latency = max(both ends).
	local a b
	a=$(lat_to_ns "$up_l1"); b=$(lat_to_ns "$ep_l1")
	# An end that reports "unlimited" exit latency makes the path unbounded.
	if [[ $a == inf || $b == inf ]]; then
		worst=inf
	else
		worst=$(( a > b ? a : b ))
	fi
	local acc
	acc=$(lat_to_ns "$acc_l1")
	if [[ $worst == inf && $acc != inf ]]; then
		echo "LATENCY L1: path exit unlimited > acceptable ${acc}ns -> kernel drops L1 from aspm_capable"
	elif [[ $acc == inf ]]; then
		echo "LATENCY L1: path exit ${worst}ns vs acceptable unlimited -> OK (kernel keeps L1)"
	elif (( worst > acc )); then
		echo "LATENCY L1: path exit ${worst}ns > acceptable ${acc}ns -> kernel drops L1 from aspm_capable"
	else
		echo "LATENCY L1: path exit ${worst}ns <= acceptable ${acc}ns -> OK"
	fi
}

sysfs_link_dump() {
	echo "policy: $(cat "$POLICY_FILE")"
	for d in "$SYS_PCI"/*; do
		[[ -d $d/link ]] || continue
		local line="${d##*/}:"
		# Some ports have an empty link/ dir; skip the unexpanded glob.
		for f in "$d"/link/*; do [[ -f $f ]] && line+=" ${f##*/}=$(cat "$f")"; done
		echo "$line"
	done
}

aer_dump() {
	local dev=$1 kind
	for kind in correctable nonfatal fatal; do
		echo "--- $dev aer_dev_$kind (nonzero only)"
		awk '$2 != 0' "$SYS_PCI/$dev/aer_dev_$kind"
	done
}

evidence() {
	echo "### cmdline";             cat /proc/cmdline
	echo "### sysfs ASPM controls"; sysfs_link_dump
	echo "### FADT IAPC_BOOT_ARCH (offset $FADT_IAPC_BOOT_ARCH_OFFSET, bit $FADT_NO_ASPM_BIT = no ASPM)"
	local raw val
	raw=$(od -An -tu2 -j "$FADT_IAPC_BOOT_ARCH_OFFSET" -N 2 "$FACP_TABLE" | tr -d ' ')
	val=$(( raw ))
	printf 'IAPC_BOOT_ARCH=0x%04x -> ASPM %s\n' "$val" \
		"$( (( val >> FADT_NO_ASPM_BIT & 1 )) && echo 'FORBIDDEN by FADT' || echo 'allowed by FADT')"
	echo "### kernel log: _OSC / FADT / ASPM / AER"
	journalctl -k -b --no-pager | grep -iE '_OSC|FADT|aspm|AER|pcieport|r8169.*(ASPM|safe)' || echo "(no matches)"
	echo "### per-link lspci + L1 latency check"
	local p
	for p in "${LINK_PAIRS[@]}"; do
		# shellcheck disable=SC2086  # intentional split of "up ep"
		link_report $p
	done
	lspci -vvv > "$OUT_DIR/lspci-vvv.txt"
	echo "(full lspci -vvv saved to $OUT_DIR/lspci-vvv.txt)"
}

ppt_avg_w() {
	local i sum=0 v
	for (( i = 0; i < PPT_SAMPLES; i++ )); do
		v=$(cat "$PPT_FILE"); sum=$(( sum + v ))
		sleep "$PPT_SAMPLE_INTERVAL_S"
	done
	awk -v s="$sum" -v n="$PPT_SAMPLES" 'BEGIN { printf "%.2f W\n", s / n / 1e6 }'
}

measure() {
	local label=$1
	echo "### measure: $label"
	echo "PPT avg over ${PPT_SAMPLES}s: $(ppt_avg_w)"
	turbostat --quiet --interval 5 -n 3 --show CPU,Busy%,PkgWatt,CorWatt 2>&1 | grep -E '^(-|CPU)' || true
}

liveness() {
	local dev=$1
	case $dev in
		0000:03:00.0)
			# Read-only direct read: proves the NVMe link survives L1 entry/exit.
			dd if=/dev/nvme0n1 of=/dev/null bs=1M count="$NVME_READ_MIB" iflag=direct status=none \
				&& echo "NVMe read ${NVME_READ_MIB} MiB OK" || echo "NVMe read FAILED"
			;;
		0000:04:00.0)
			local gw
			gw=$(ip -4 route show default | awk '{print $3; exit}')
			[[ -n $gw ]] || { echo "no default gateway; skipping ping"; return 0; }
			ping -c "$PING_COUNT" -q "$gw" | tail -n2 || echo "ping $gw FAILED"
			;;
	esac
}

ORIG_VALUE=""
TARGET_ATTR=""
restore() {
	if [[ -n $TARGET_ATTR && -n $ORIG_VALUE ]]; then
		echo "$ORIG_VALUE" > "$TARGET_ATTR"
		echo "RESTORED $TARGET_ATTR=$(cat "$TARGET_ATTR") (wanted $ORIG_VALUE)"
	fi
}

toggle() {
	local dev=$1 ok=0 a
	for a in "${TOGGLE_ALLOWED[@]}"; do [[ $dev == "$a" ]] && ok=1; done
	(( ok )) || die "$dev not in allowlist (${TOGGLE_ALLOWED[*]}); GPU link deliberately excluded"
	TARGET_ATTR="$SYS_PCI/$dev/link/l1_aspm"
	[[ -w $TARGET_ATTR ]] || die "$TARGET_ATTR missing: kernel does not consider L1 capable on this link"
	ORIG_VALUE=$(cat "$TARGET_ATTR")
	local new=$(( 1 - ORIG_VALUE ))
	local since
	since=$(date '+%Y-%m-%d %H:%M:%S')
	# Signals just exit; the EXIT trap does the restore exactly once. PIPE covers tee dying on SSH drop.
	trap restore EXIT
	trap 'exit 1' INT TERM HUP PIPE

	echo "### $dev l1_aspm: $ORIG_VALUE -> $new (restored to $ORIG_VALUE on exit)"
	aer_dump "$dev"
	measure "before (l1_aspm=$ORIG_VALUE)"
	echo "$new" > "$TARGET_ATTR"
	echo "wrote: l1_aspm=$(cat "$TARGET_ATTR")"
	lspci -vvv -s "$dev" | lspci_line 'LnkCtl:'
	echo "settling ${SETTLE_SECONDS}s"; sleep "$SETTLE_SECONDS"
	liveness "$dev"
	measure "after (l1_aspm=$new)"
	aer_dump "$dev"
	echo "### kernel log since $since"
	journalctl -k --no-pager --since "$since" | grep -iE 'AER|nvme|r8169|enp4s0|pcieport|timeout|reset' \
		|| echo "(no AER/nvme/r8169 messages)"
	# restore() runs via the EXIT trap.
}

main() {
	local mode=${1:-evidence}
	case $mode in
		evidence) evidence ;;
		toggle) [[ -n ${2:-} ]] || die "toggle needs a BDF, e.g. 0000:04:00.0"; toggle "$2" ;;
		*) die "unknown mode '$mode' (evidence|toggle BDF)" ;;
	esac
}

main "$@" 2>&1 | tee "$OUT_DIR/report.txt"
