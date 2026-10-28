#!/usr/bin/env bash
#
# vramtemp-pan-rijovich.sh -- one GDDR6 temperature read on the BC-250 with
# pan-Rijovich/bc250-memory-temperature. USER-RUN ONLY, as root.
#
# ============================== RISK ======================================
# patch_smu.py opens the SMU debug gate with a memory-corruption exploit of
# Queue 2 message 0x23 (unlock.py), writes SMUPayload.bin into SMU RAM at
# 0x3AA9C and repoints Queue 3 messages 5-7 at it. read_temp.py then drives
# GDDR6 MR3 temperature readout over the DQ bus. Upstream warns this can
# corrupt memory or crash; a hang needs a hard power cycle. The patch stays
# until power is removed. Nothing is flashed.
# ===========================================================================
#
# Usage: sudo ./vramtemp-pan-rijovich.sh /path/to/bc250-memory-temperature [seconds]
# SKIP_PATCH=1 reads only, for a second run in the same power cycle:
# patch_smu.py refuses to patch twice.
set -euo pipefail

# The revision and hashes BC250 Control Center reviewed and pins
# (privileged/helpers/bc250-gddr6-temp-helper).
readonly REVIEWED_REVISION=4a2221d1da387fa2e738bb9368b39594e242ba4b
readonly REVIEWED_SHA256="\
04e69ef1e4c1ec3051d97ed8c3cb68eb31b43c2be3cdb921f1d3957f99aa32ed  patch_smu.py
86bc1aaa3265c7a62d28570953e6a47047a6aaa95661c6c649a5822a4165e3b4  unlock.py
ad87f03cc35aaa0da4e75d6e45bd56bc5baa7c1e680a25b528c3c6fce480884a  bc250_smu/__init__.py
7fe9beed4fa12bb8625096859ff32e8ee64ee8b9cb1265f1546b5cc7127422fc  bc250_smu/api.py
b1e0afa14b2a75a73d30308019ee7199733a59ad946210fae91ee2d675256ad1  bc250_smu/api_q0.py
811de63b7e3c3eb23808971ae7c6b0cc661cc52fc0d9c9b7a055aa25cfb9b31a  bc250_smu/api_q1.py
cc3db581a1c8136664d4520d6d96c35449c768df621eea3c3a1c5101fa612e78  bc250_smu/api_q2.py
e5f5021643d866c78a9117e15f7f085edcd19173d1e26c5282ff7b8cc660e7c3  bc250_smu/api_q3.py
011baa51294b043b7e636b3e7e441184061fe9a37534125330e28afc6fc5d2ff  bc250_smu/api_q4.py
bb747622598b92ff43f10583ef93803bda4d6ae59b2480e74fc2abf6751db116  bc250_smu/codec.py
eec00a893b809d64f176cfd375179be84643221628b571ea5b5a3bc0e753d7c4  bc250_smu/errors.py
2efaaa10f2d7285c2587c892f9633000ea400c93d8492d4fbf7ed1e54de3622c  bc250_smu/mailbox.py
8ea7262d4b548933530889858d40fac5eeb3aaaa42dbb167e4bdeaec36b6f50b  bc250_smu/primitives.py
8030084a9aae7c20e8ea787fca72f2a2bc75d9c2305d62047d6f0a5b2fe2d39d  bc250_smu/transport.py
32ab902bb07a5a00cdb54f8686b8944fed8cb30abf394c395d5e8d421f756529  SMUPayload.bin
16c3baadae4a6790c315c71107e7ca9343dedd0d624d5bdaa507dc00ffe655a1  SMUPayload.symbols"
# Control Center does not pin read_temp.py (it has its own reader).
readonly READER=read_temp.py
readonly GOVERNOR_UNIT=cyan-skillfish-governor-smu.service
# Control Center refuses within 5 s of a governor start: its Queue 3 startup
# messages have hung boards when a sample landed in between.
readonly GOVERNOR_STOP_SETTLE_S=5
readonly DEFAULT_READ_SECONDS=30
readonly READ_INTERVAL_S=2
# Same lock file the governor and Control Center take around 0xB8/0xBC.
readonly SMN_WINDOW=/sys/bus/pci/devices/0000:00:00.0/config
readonly LOG_DIR=/var/log/bc250-vramtemp

log() { echo "[$(date +%T)] $*" >&2; }

[[ $EUID -eq 0 ]] || { log "run as root"; exit 1; }
[[ $# -ge 1 ]] || { log "usage: $0 CHECKOUT [seconds]"; exit 1; }
checkout=$1
read_seconds=${2:-$DEFAULT_READ_SECONDS}

head=$(git -c safe.directory="$checkout" -C "$checkout" rev-parse HEAD)
[[ $head == "$REVIEWED_REVISION" ]] || { log "checkout is at $head, want $REVIEWED_REVISION"; exit 1; }
(cd "$checkout" && sha256sum --quiet -c <<<"$REVIEWED_SHA256")
log "checkout matches the reviewed revision and hashes"

# Run root Python from a root-owned copy, not the user's writable checkout.
stage=$(mktemp -d /root/bc250-vramtemp.XXXXXX)
mapfile -t files < <(awk '{print $2}' <<<"$REVIEWED_SHA256")
(cd "$checkout" && cp --parents "${files[@]}" "$READER" "$stage/")
(cd "$stage" && sha256sum --quiet -c <<<"$REVIEWED_SHA256")
mkdir -p "$LOG_DIR"
out="$LOG_DIR/read-$(date +%Y%m%d-%H%M%S).log"

governor_was_active=0
cleanup() {
	local status=$?
	if [[ $governor_was_active -eq 1 ]]; then
		log "restarting $GOVERNOR_UNIT"
		systemctl start "$GOVERNOR_UNIT" || log "governor restart FAILED: start it by hand"
	fi
	rm -rf "$stage"
	[[ $status -eq 0 ]] || log "FAILED (exit $status)"
}
trap cleanup EXIT

if systemctl is-active --quiet "$GOVERNOR_UNIT"; then
	governor_was_active=1
	log "stopping $GOVERNOR_UNIT"
	systemctl stop "$GOVERNOR_UNIT"
fi
sleep "$GOVERNOR_STOP_SETTLE_S"
log "SMU firmware: $(grep -i smc /sys/kernel/debug/dri/1/amdgpu_firmware_info 2>/dev/null || echo unknown)"

# Hexxeh's module drives 0xB8/0xBC from the kernel, outside any lock.
if grep -q '^bc250_memory ' /proc/modules; then
	log "bc250_memory module is loaded: unload it first"; exit 1
fi

sync
cd "$stage"
# -E -s: ignore PYTHON* and user site; the script dir (root-owned) stays on
# sys.path so bc250_smu imports from the staged copy.
exec 9<"$SMN_WINDOW"
flock 9
if [[ ${SKIP_PATCH:-0} == 1 ]]; then
	log "SKIP_PATCH=1: reading with the payload already in SMU RAM" | tee "$out"
else
	log "patching SMU (unlock + payload)"
	python3 -E -s patch_smu.py 2>&1 | tee "$out"
fi
log "reading for ${read_seconds}s every ${READ_INTERVAL_S}s"
# SIGINT so read_temp.py finishes its current mailbox transaction.
timeout -s INT "$read_seconds" python3 -E -s "$READER" -i "$READ_INTERVAL_S" -l "$LOG_DIR/smu_error.log" 2>&1 \
	| tee -a "$out" || [[ ${PIPESTATUS[0]} -eq 124 ]]
flock -u 9
log "done; output in $out"
