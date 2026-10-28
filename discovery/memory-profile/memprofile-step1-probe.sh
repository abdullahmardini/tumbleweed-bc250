#!/usr/bin/env bash
#
# memprofile-step1-probe.sh -- step 1 of the BC-250 memory/fabric profile
# experiment. USER-RUN ONLY, as root.
#
# ============================== RISK ======================================
# This script talks to the SMU mailbox (Queue 3) through the PCI config
# index/data pair 0xB8/0xBC on 00:00.0. It STOPS cyan-skillfish-governor-smu
# for a few seconds (GPU clocks stay wherever the governor left them, then the
# trap restarts it). By default it sends ONE message: Queue 3 0x01 (test
# message, arg 123, expect 124). The governor itself sends that exact message
# every time it starts, so this is the lowest-risk message there is; it proves
# the script's mailbox plumbing before step 2 trusts it with a write.
#
# There is NO "get current memory profile" message. Queue 3 0x1E is set-only
# (governor src/smu/api/queue3.rs:92-95, no decode). The only read-back that
# needs no SMU message from us is pp_dpm_mclk / gpu_metrics current_uclk
# (SMU metrics MemclkFrequency, kept at the same offset on 8-core boards);
# this script prints it before and after.
#
# --read-table additionally sends Queue 3 0x41 ("read from perf profile
# table", arg = index) and 0x3B ("get clk assigned to P-state", arg = pstate)
# for indices 0..3. Their meaning is reverse-engineered guesswork
# ("functionality unclear" in the crate). They return a value and are named as
# reads, but an unknown message can have unknown side effects. Opt in only if
# you accept that. Nothing here sends 0x1E.
#
# Residual risk: amdgpu also uses 0xB8/0xBC; userspace cannot take its lock.
# Same exposure as bc250-8core-unlock. A hung SMU means a hard power cycle.
# ===========================================================================
#
# Usage: sudo ./memprofile-step1-probe.sh [--read-table]
set -euo pipefail

readonly GOVERNOR_UNIT=cyan-skillfish-governor-smu.service
readonly PCI_DEV=00:00.0
readonly IDX=0xB8                     # SMN address register
readonly DAT=0xBC                     # SMN data register
# Queue 3 mailbox (governor src/smu/mod.rs:19)
readonly Q3_CMD=03B10A20
readonly Q3_RSP=03B10A80
readonly Q3_ARG0=03B10A88
readonly Q3_ARG1=03B10A8C
readonly MSG_TEST=01
readonly MSG_READ_PROFILE_TABLE=41
readonly MSG_GET_CLK_FOR_PSTATE=3B
readonly TEST_ARG=123                 # governor check_test_message() uses 123
readonly TEST_EXPECT=$((TEST_ARG + 1))
readonly POLL_MAX=500                 # governor Bc250Smu::new(..., 500)
readonly SMU_OK=1                     # mailbox.rs:8 status codes
readonly SMU_ERR_MIN=252              # 0xFC busy .. 0xFF failed
readonly TABLE_INDICES="0 1 2 3"
readonly GOVERNOR_STOP_SETTLE_S=1     # let the governor's last mailbox op finish
readonly DRM_DEV=/sys/class/drm/card1/device

die() { echo "error: $*" >&2; exit 1; }

read_table=0
case "${1:-}" in
    "") ;;
    --read-table) read_table=1 ;;
    *) die "usage: $0 [--read-table]" ;;
esac

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v setpci >/dev/null || die "setpci not found (pciutils)"
[ -e "/sys/bus/pci/devices/0000:$PCI_DEV/config" ] || die "no PCI device $PCI_DEV"

governor_was_active=0
saved_index=""
restore() {
    # Runs on every exit path: put the SMN index back, then the governor.
    if [ -n "$saved_index" ]; then
        setpci -s "$PCI_DEV" "$IDX.L=$saved_index" \
            || echo "warning: could not restore SMN index $saved_index" >&2
    fi
    if [ "$governor_was_active" -eq 1 ]; then
        systemctl start "$GOVERNOR_UNIT" \
            || echo "WARNING: governor did not restart: systemctl start $GOVERNOR_UNIT" >&2
        echo "governor: $(systemctl is-active "$GOVERNOR_UNIT" || true)"
    fi
}
trap restore EXIT

smn_read() { setpci -s "$PCI_DEV" "$IDX.L=$1" && setpci -s "$PCI_DEV" "$DAT.L"; }

# One setpci call for the whole write sequence (same pattern as
# bc250-8core-unlock) so the index/data pairs are not split across processes.
# Order matches mailbox.rs:59-62: clear rsp, arg0, arg1, then message id.
q3_send() {   # $1 = msg id hex (no 0x), $2 = arg decimal -> prints arg0 after
    local msg=$1 arg=$2 i resp raw
    setpci -s "$PCI_DEV" \
        "$IDX.L=$Q3_RSP"  "$DAT.L=00000000" \
        "$IDX.L=$Q3_ARG0" "$DAT.L=$(printf '%08x' "$arg")" \
        "$IDX.L=$Q3_ARG1" "$DAT.L=00000000" \
        "$IDX.L=$Q3_CMD"  "$DAT.L=000000$msg"
    resp=0
    for ((i = 0; i < POLL_MAX; i++)); do
        raw=$(smn_read "$Q3_RSP") || { echo "SMN read of response failed" >&2; return 1; }
        resp=$((0x$raw))
        if [ "$resp" -eq "$SMU_OK" ] || [ "$resp" -ge "$SMU_ERR_MIN" ]; then
            break
        fi
    done
    if [ "$resp" -ne "$SMU_OK" ]; then
        printf 'Q3 msg 0x%s arg %d: status 0x%02X (timeout if 0)\n' "$msg" "$arg" "$resp" >&2
        return 1
    fi
    raw=$(smn_read "$Q3_ARG0") || { echo "SMN read of arg0 failed" >&2; return 1; }
    echo $((0x$raw))
}

mclk() { grep '\*' "$DRM_DEV/pp_dpm_mclk" | tr -d '\n'; }

echo "before: pp_dpm_mclk [$(mclk)]  pp_dpm_fclk [$(grep '\*' "$DRM_DEV/pp_dpm_fclk" | tr -d '\n')]"

if systemctl is-active --quiet "$GOVERNOR_UNIT"; then
    governor_was_active=1
    systemctl stop "$GOVERNOR_UNIT"
    sleep "$GOVERNOR_STOP_SETTLE_S"
fi
saved_index=$(setpci -s "$PCI_DEV" "$IDX.L")

got=$(q3_send "$MSG_TEST" "$TEST_ARG") || die "test message failed; not sending anything else"
[ "$got" -eq "$TEST_EXPECT" ] || die "test message returned $got, expected $TEST_EXPECT"
echo "Q3 0x01 test message: $TEST_ARG -> $got (OK)"

if [ "$read_table" -eq 1 ]; then
    for idx in $TABLE_INDICES; do
        v41=$(q3_send "$MSG_READ_PROFILE_TABLE" "$idx") || v41="error"
        v3b=$(q3_send "$MSG_GET_CLK_FOR_PSTATE" "$idx") || v3b="error"
        echo "index $idx: Q3 0x41 -> $v41   Q3 0x3B -> $v3b"
    done
fi

echo "after:  pp_dpm_mclk [$(mclk)]"
