#!/usr/bin/env bash
#
# smu-features.sh -- read, and opt-in enable, SMU firmware power features on
# the BC-250 (SMU v11.8, firmware 88.6.0).
#
# Why: amdgpu never asks. cyan_skillfish_get_enabled_mask() fills the mask with
# ones, so sysfs cannot show which power features the firmware runs, and
# several deep-sleep (DS_*) features are off.
#
# status: queue 0 TestMessage, GetSmuVersion, GetEnabledSmuFeatures. Read-only.
# enable: ONE feature per call, through the reverse-engineered EnableSmuFeatures
#   on queue 2 (0x05, governor queue2.rs) or queue 3 (0x3C, queue3.rs); which
#   one the firmware honours is unknown, so the queue is an argument. The mask
#   is read back after. Nothing is flashed: a power cycle reverts it. An enabled
#   feature can hang the board; save work first.
#
# Queue 0 is shared with amdgpu, which serialises it with its own mutex that
# setpci cannot take. The governor is stopped meanwhile (it drives every
# queue); an amdgpu sysfs read in the ~ms window could still collide, so close
# GPU monitors first.
#
# Usage: sudo ./smu-features.sh status
#        sudo ./smu-features.sh enable FEATURE_NAME q2|q3
set -euo pipefail

readonly GOVERNOR_UNIT=cyan-skillfish-governor-smu.service
readonly GOVERNOR_STOP_SETTLE_S=1
readonly POST_ENABLE_SETTLE_S=2
readonly PCI_DEV=00:00.0
readonly IDX=0xB8
readonly DAT=0xBC
# Mailboxes: cmd rsp arg (governor src/smu/mod.rs:15-21); arg high is arg + 4
readonly Q0=(03B10A08 03B10A68 03B10A48)
readonly Q2=(03B10528 03B10564 03B10998)
readonly Q3=(03B10A20 03B10A80 03B10A88)
# smu_v11_8_ppsmc.h (queue 0)
readonly MSG_TEST=01
readonly MSG_GET_SMU_VERSION=02
readonly MSG_GET_ENABLED_FEATURES=3D
readonly MSG_Q2_ENABLE_FEATURES=05      # governor queue2.rs enable_smu_features
readonly MSG_Q3_ENABLE_FEATURES=3C      # governor queue3.rs q3_enable_smu_features
readonly TEST_ARG=123
readonly TEST_EXPECT=$((TEST_ARG + 1))
readonly EXPECTED_SMU_VERSION=$((0x00580600))   # 88.6.0, the only firmware seen here
# 88.6.0 ignores the argument of 0x3D and returns bits 0-31 (2026-10-28)
readonly READABLE_FEATURE_BITS=32
readonly POLL_MAX=500
readonly SMU_OK=1
readonly SMU_ERR_MIN=252

# smu_v11_8_pmfw.h, bits 0-36 (37-63 are SPARE)
readonly FEATURE_NAMES=(
    CCLK_CONTROLLER GFXCLK_EFFT_FREQ DATA_CALCULATION THERMAL PLL_POWER_DOWN
    FCLK_DPM GFX_DPM DS_GFXCLK DS_SOCCLK DS_LCLK CORE_CSTATES G6_SSC RM SOC_DPM
    DS_SMNCLK DS_MP1CLK DS_MP0CLK MGCG DS_FUSE_SRAM GFX_CKS FP_THROTTLING
    PROCHOT CPUOFF UMC_THROTTLE DF_THROTTLE DS_MP3CLK DS_SHUBCLK TDC
    UMC_CAL_SHARING DFLL_BTC_CALIBRATION EDC DLDO MEAS_DRAM_BLACKOUT CC1 PPT
    STAPM CSTATE_BOOST
)

die() { echo "error: $*" >&2; exit 1; }
log() { echo "$(date -Is) $*"; }

feature_bit() {   # $1 = name -> prints bit number
    local i
    for ((i = 0; i < ${#FEATURE_NAMES[@]}; i++)); do
        [ "${FEATURE_NAMES[$i]}" = "$1" ] && { echo "$i"; return 0; }
    done
    return 1
}

cmd=${1:-}
case "$cmd" in
    status) ;;
    enable)
        name=${2:-}; queue=${3:-}
        bit=$(feature_bit "$name") || die "unknown feature '$name'"
        [ "$bit" -lt "$READABLE_FEATURE_BITS" ] || die "$name is bit $bit; cannot be read back, refusing"
        case "$queue" in
            q2) MBOX=("${Q2[@]}"); MSG_ENABLE=$MSG_Q2_ENABLE_FEATURES ;;
            q3) MBOX=("${Q3[@]}"); MSG_ENABLE=$MSG_Q3_ENABLE_FEATURES ;;
            *) die "queue must be q2 or q3" ;;
        esac
        ;;
    *) die "usage: $0 status | enable FEATURE_NAME q2|q3" ;;
esac

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v setpci >/dev/null || die "setpci not found (pciutils)"
[ "$(setpci -s "$PCI_DEV" 0.L)" = 13e01022 ] || die "$PCI_DEV is not 1022:13e0 (BC-250 root complex)"

smn_read() { setpci -s "$PCI_DEV" "$IDX.L=$1" && setpci -s "$PCI_DEV" "$DAT.L"; }

mbox_send() {   # $1 cmd $2 rsp $3 arg $4 msg hex $5 arg decimal -> prints reply arg
    local c=$1 r=$2 a=$3 msg=$4 arg=$5 i resp raw
    local a_high
    a_high=$(printf '%08X' $((0x$a + 4)))
    setpci -s "$PCI_DEV" \
        "$IDX.L=$r"      "$DAT.L=00000000" \
        "$IDX.L=$a"      "$DAT.L=$(printf '%08x' "$arg")" \
        "$IDX.L=$a_high" "$DAT.L=00000000" \
        "$IDX.L=$c"      "$DAT.L=000000$msg"
    resp=0
    for ((i = 0; i < POLL_MAX; i++)); do
        raw=$(smn_read "$r") || { echo "SMN read of response failed" >&2; return 1; }
        resp=$((0x$raw))
        if [ "$resp" -eq "$SMU_OK" ] || [ "$resp" -ge "$SMU_ERR_MIN" ]; then
            break
        fi
    done
    if [ "$resp" -ne "$SMU_OK" ]; then
        printf 'mailbox %s msg 0x%s arg %d: status 0x%02X (timeout if 0)\n' "$c" "$msg" "$arg" "$resp" >&2
        return 1
    fi
    raw=$(smn_read "$a") || { echo "SMN read of arg failed" >&2; return 1; }
    echo $((0x$raw))
}

q0_send() { mbox_send "${Q0[0]}" "${Q0[1]}" "${Q0[2]}" "$1" "$2"; }

read_mask() {
    q0_send "$MSG_GET_ENABLED_FEATURES" 0
}

print_mask() {   # $1 = mask
    local bit state
    printf 'enabled features (bits 0-31): 0x%08X\n' "$1"
    for ((bit = 0; bit < READABLE_FEATURE_BITS; bit++)); do
        if (( ($1 >> bit) & 1 )); then state=on; else state=off; fi
        printf '%2d %-22s %s\n' "$bit" "${FEATURE_NAMES[$bit]}" "$state"
    done
}

governor_was_active=0
saved_index=""
cleanup() {
    [ -n "$saved_index" ] && setpci -s "$PCI_DEV" "$IDX.L=$saved_index"
    if [ "$governor_was_active" -eq 1 ]; then
        systemctl start "$GOVERNOR_UNIT" \
            || echo "WARNING: governor did not restart: systemctl start $GOVERNOR_UNIT" >&2
    fi
    echo "governor: $(systemctl is-active "$GOVERNOR_UNIT" || true)"
}
trap cleanup EXIT

if systemctl is-active --quiet "$GOVERNOR_UNIT"; then
    governor_was_active=1
    systemctl stop "$GOVERNOR_UNIT"
    sleep "$GOVERNOR_STOP_SETTLE_S"
fi
saved_index=$(setpci -s "$PCI_DEV" "$IDX.L")

got=$(q0_send "$MSG_TEST" "$TEST_ARG") || die "test message failed"
[ "$got" -eq "$TEST_EXPECT" ] || die "test message returned $got, expected $TEST_EXPECT"
ver=$(q0_send "$MSG_GET_SMU_VERSION" 0) || die "GetSmuVersion failed"
printf 'SMU version: 0x%08X\n' "$ver"
[ "$ver" -eq "$EXPECTED_SMU_VERSION" ] || die "unexpected SMU version; stopping"

before=$(read_mask) || die "GetEnabledSmuFeatures failed"

if [ "$cmd" = status ]; then
    print_mask "$before"
    exit 0
fi

(( (before >> bit) & 1 )) && die "$name (bit $bit) is already on"
sync   # a hang after the enable loses nothing written so far
log "enable $name (bit $bit) via $queue msg 0x$MSG_ENABLE, mask before 0x$(printf '%08X' "$before")"
mbox_send "${MBOX[0]}" "${MBOX[1]}" "${MBOX[2]}" "$MSG_ENABLE" $((1 << bit)) >/dev/null \
    || die "enable returned an error status; feature state unknown"
sleep "$POST_ENABLE_SETTLE_S"
after=$(read_mask) || die "GetEnabledSmuFeatures after enable failed"
log "mask after 0x$(printf '%08X' "$after")"
if (( (after >> bit) & 1 )); then
    log "$name is ON"
else
    log "$name still OFF: firmware accepted the message but did not enable it"
    exit 2
fi
changed=$(( before ^ after ^ (1 << bit) ))
[ "$changed" -eq 0 ] || log "WARNING: other bits changed too: 0x$(printf '%08X' "$changed")"
