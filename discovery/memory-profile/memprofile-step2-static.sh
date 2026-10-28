#!/usr/bin/env bash
#
# memprofile-step2-static.sh -- step 2 of the BC-250 memory/fabric profile
# experiment: ONE static write of SMU Queue 3 message 0x1E, then a soak log.
# USER-RUN ONLY, as root.
#
# ============================== RISK ======================================
# Queue 3 0x1E re-clocks GDDR6, the memory controller and the data fabric
# together, live. It is undocumented. Community reports on BC-250:
#   - about 1 write in 20 fabric-faults and LOCKS the APU (dan2wik). A lockup
#     needs a hard power cycle; unsaved work is lost; the filesystem takes an
#     unclean shutdown.
#   - repeatedly cycling profiles "will eventually crash" (iridium.io).
# So: every write, INCLUDING the restore to 3, is one roll of that dice. This
# script makes exactly one write per invocation, refuses a second `set` in the
# same boot, and never cycles. Close everything you care about first, sync,
# and run it from a text console or ssh if you can.
# Nothing is flashed. Power removal (cold boot) reloads the SMU firmware and
# brings the default profile 3 back. Whether a WARM reboot also resets it is
# not known. Rebooting is your call.
# ===========================================================================
#
# Usage:
#   sudo ./memprofile-step2-static.sh set       # one write: profile TARGET_PROFILE
#   sudo ./memprofile-step2-static.sh soak      # log for SOAK_SECONDS (governor keeps running)
#   sudo ./memprofile-step2-static.sh restore   # one write: profile DEFAULT_PROFILE
set -euo pipefail

# Profile 2 (~850 MHz): filippor measured idle wall 82 -> 65 -> 59 W for
# profiles 3 -> 2 -> 1, so 2 gets ~3/4 of the saving at half the clock drop,
# and keeps 12.4 GiB/s CPU DRAM bandwidth (branch defaults) for scanout and the
# desktop vs 4.0 GiB/s at profile 1. Profile 0 is outside the branch's 1..3
# range (examples/set_memory_profile.rs:10) and is not offered.
readonly TARGET_PROFILE=2
readonly DEFAULT_PROFILE=3            # firmware default; the branch's reset()
readonly SOAK_SECONDS=$((8 * 3600))   # one overnight idle soak
readonly LOG_INTERVAL_S=10
readonly POST_WRITE_SETTLE_S=2        # capacity example waits 1 s after a write
readonly GOVERNOR_STOP_SETTLE_S=1

readonly GOVERNOR_UNIT=cyan-skillfish-governor-smu.service
readonly PCI_DEV=00:00.0
readonly IDX=0xB8
readonly DAT=0xBC
readonly Q3_CMD=03B10A20              # governor src/smu/mod.rs:19
readonly Q3_RSP=03B10A80
readonly Q3_ARG0=03B10A88
readonly Q3_ARG1=03B10A8C
readonly MSG_TEST=01
readonly MSG_SET_PERF_PROFILE=1E      # queue3.rs:92 q3_set_perf_profile_index
readonly TEST_ARG=123
readonly TEST_EXPECT=$((TEST_ARG + 1))
readonly POLL_MAX=500
readonly SMU_OK=1
readonly SMU_ERR_MIN=252

readonly DRM_DEV=/sys/class/drm/card1/device
readonly GPU_METRICS=$DRM_DEV/gpu_metrics
# gpu_metrics_v2_2 byte offsets (kgd_pp_interface.h)
readonly GM_SOCKET_POWER=40           # average_socket_power = CurrentSocketPower, mW (= PPT)
readonly GM_SOC_POWER=44              # VDDCR_VDD (CPU rail), mW
readonly GM_GFX_POWER=46              # VDDCR_GFX, mW
readonly GM_CUR_UCLK=80               # current_uclk, MHz
# Persistent, per-boot state: /run is tmpfs, so a reboot clears the guard.
readonly STATE_FILE=/run/bc250-memprofile.last
readonly LOG_FILE=/var/log/bc250-memprofile-soak.log

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v setpci >/dev/null || die "setpci not found (pciutils)"

smn_read() { setpci -s "$PCI_DEV" "$IDX.L=$1" && setpci -s "$PCI_DEV" "$DAT.L"; }

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

u16_at() { od -An -tu2 -j "$1" -N2 "$GPU_METRICS" | tr -d ' '; }
cur_mhz() { sed -n 's/^0: \([0-9]*\)Mhz \*$/\1/p' "$DRM_DEV/$1"; }

log() { echo "$(date -Is) $*" | tee -a "$LOG_FILE"; sync "$LOG_FILE"; }

# Globals, not locals: the EXIT trap runs after write_profile_once returns.
governor_was_active=0
saved_index=""
restore_trap() {
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

write_profile_once() {   # $1 = profile
    local profile=$1 got
    trap restore_trap EXIT

    log "before write: mclk=$(cur_mhz pp_dpm_mclk) fclk=$(cur_mhz pp_dpm_fclk) uclk(gpu_metrics)=$(u16_at $GM_CUR_UCLK)"
    sync   # a lockup now loses nothing that was written

    # The governor (v0.4.14) never sends 0x1E, but it shares the 0xB8/0xBC
    # pair with flock per 4-byte access only, so a second writer would split
    # its index/data pairs. Stop it for the write.
    if systemctl is-active --quiet "$GOVERNOR_UNIT"; then
        governor_was_active=1
        systemctl stop "$GOVERNOR_UNIT"
        sleep "$GOVERNOR_STOP_SETTLE_S"
    fi
    saved_index=$(setpci -s "$PCI_DEV" "$IDX.L")

    got=$(q3_send "$MSG_TEST" "$TEST_ARG") || die "test message failed; 0x1E NOT sent"
    [ "$got" -eq "$TEST_EXPECT" ] || die "test message returned $got, expected $TEST_EXPECT; 0x1E NOT sent"

    # Record the attempt BEFORE sending: an error status leaves the profile
    # unknown, and the guard must still block a retry (a retry is a cycle).
    echo "$profile $(date -Is)" > "$STATE_FILE"
    log "sending Q3 0x1E arg $profile"
    q3_send "$MSG_SET_PERF_PROFILE" "$profile" >/dev/null \
        || die "0x1E returned an error status; profile state unknown"
    sleep "$POST_WRITE_SETTLE_S"
    log "after write: profile=$profile status=OK mclk=$(cur_mhz pp_dpm_mclk) fclk=$(cur_mhz pp_dpm_fclk) uclk(gpu_metrics)=$(u16_at $GM_CUR_UCLK)"
    # trap restarts the governor (it does not touch 0x1E, so the profile stays)
}

soak() {
    local end=$(( $(date +%s) + SOAK_SECONDS )) kerr_since
    kerr_since=$(date '+%Y-%m-%d %H:%M:%S')
    log "soak start: ${SOAK_SECONDS}s every ${LOG_INTERVAL_S}s; last write: $(cat "$STATE_FILE" 2>/dev/null || echo none this boot)"
    log "columns: mclk_MHz fclk_MHz uclk_MHz PPT_W socket_mW soc_mW gfx_mW load1 amdgpu_kernel_errors_since_start"
    while [ "$(date +%s)" -lt "$end" ]; do
        local ppt kerr
        ppt=$(awk '{printf "%.2f", $1/1e6}' "$DRM_DEV"/hwmon/hwmon*/power1_input)
        kerr=$(journalctl -k -p err --since "$kerr_since" --no-pager -q | grep -ci amdgpu || true)
        log "$(cur_mhz pp_dpm_mclk) $(cur_mhz pp_dpm_fclk) $(u16_at $GM_CUR_UCLK) $ppt" \
            "$(u16_at $GM_SOCKET_POWER) $(u16_at $GM_SOC_POWER) $(u16_at $GM_GFX_POWER)" \
            "$(cut -d' ' -f1 /proc/loadavg) $kerr"
        sleep "$LOG_INTERVAL_S"
    done
    log "soak end"
}

case "${1:-}" in
    set)
        [ -e "$STATE_FILE" ] && die "already wrote this boot ($(cat "$STATE_FILE")); no cycling. Use 'restore' or reboot."
        write_profile_once "$TARGET_PROFILE"
        echo "Now record your wall meter and run: sudo $0 soak"
        ;;
    restore)
        [ -e "$STATE_FILE" ] || die "no write recorded this boot; profile should already be $DEFAULT_PROFILE"
        read -r last _ < "$STATE_FILE"
        [ "$last" = "$DEFAULT_PROFILE" ] && die "already restored to $DEFAULT_PROFILE this boot"
        write_profile_once "$DEFAULT_PROFILE"
        ;;
    soak) soak ;;
    *) die "usage: $0 {set|soak|restore}" ;;
esac
