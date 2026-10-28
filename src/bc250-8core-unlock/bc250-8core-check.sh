#!/usr/bin/bash
#
# bc250-8core-check -- warn when the BC-250 core mask is 0xFF but the extra
# cores are not online yet.
#
# Runs as ExecStartPost= of bc250-8core-unlock.service, so only after
# "bc250-8core-unlock boot" exited 0, which means the mask reads 0xFF (already,
# or just set). Firmware fixes the CPU topology at reset, so after a cold boot
# the unit sets the mask and the system keeps running on the factory 6 cores
# until the next warm reboot. This check makes that state visible instead of
# silent. It reads sysfs only; it never touches the SMU.
#
# Exit status (the unit runs it with a "-" prefix, so none of these fail the
# unit or hold up the governor; systemctl status shows the code on the
# ExecStartPost line):
#   0  all threads of the unlocked mask are online
#   2  factory thread count online: warm reboot pending (warning + motd)
#   3  any other thread count (warning + motd)
#   1  the online CPU list could not be read or parsed
#
set -euo pipefail

UNLOCKED_CORES=8               # mask 0xFF
FACTORY_CORES=6                # mask 0x77
THREADS_PER_CORE=2             # SMT
EXPECTED_THREADS=$((UNLOCKED_CORES * THREADS_PER_CORE))   # 16
FACTORY_THREADS=$((FACTORY_CORES * THREADS_PER_CORE))     # 12

EXIT_OK=0
EXIT_ERROR=1
EXIT_REBOOT_PENDING=2
EXIT_UNEXPECTED_COUNT=3

# Overridable only so the decision logic can be tested against fake inputs.
CPU_ONLINE=${BC250_CPU_ONLINE:-/sys/devices/system/cpu/online}
# pam_motd (login, sshd) shows every file in /run/motd.d. /run is a tmpfs,
# so the notice disappears by itself on the next boot.
MOTD_FILE=${BC250_MOTD_FILE:-/run/motd.d/bc250-8core-unlock}

# Under systemd, stderr goes to the journal; a "<N>" prefix sets the syslog
# priority (SyslogLevelPrefix= defaults to yes). JOURNAL_STREAM names the
# journal stream's device:inode, but children inherit it, so compare it with
# stderr (as sd_journal_stream_fd(3) advises): an interactive run from a
# service-spawned shell then prints plain text.
to_journal=no
if [[ -n ${JOURNAL_STREAM:-} ]] \
    && [[ $(stat -L -c '%d:%i' /proc/self/fd/2) == "$JOURNAL_STREAM" ]]; then
    to_journal=yes
fi
log() {                                        # $1 = priority 0..7, $2 = text
    if [[ $to_journal == yes ]]; then
        printf '<%d>%s\n' "$1" "$2" >&2
    else
        printf '%s\n' "$2" >&2
    fi
}
LOG_ERR=3
LOG_WARNING=4
LOG_INFO=6

# Count the CPUs in a kernel cpulist such as "0-15" or "0-3,5,8-11".
count_cpulist() {                              # $1 = cpulist -> count
    local list=$1 part lo hi total=0
    [[ $list =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 1
    local IFS=,
    for part in $list; do
        lo=${part%-*}
        hi=${part#*-}
        (( hi >= lo )) || return 1
        total=$(( total + hi - lo + 1 ))
    done
    echo "$total"
}

# main runs in an "||" list, where set -e is off: check each write here.
# A failed write is logged but does not change the exit status, which
# already carries the warning.
notify() {                                     # $1 = notice text
    if ! { mkdir -p "$(dirname "$MOTD_FILE")" && printf '%s\n' "$1" >"$MOTD_FILE"; }; then
        log "$LOG_ERR" "error: cannot write the login notice $MOTD_FILE"
    fi
}

main() {
    local list online msg
    if ! list=$(<"$CPU_ONLINE"); then
        log "$LOG_ERR" "error: cannot read $CPU_ONLINE"
        return "$EXIT_ERROR"
    fi
    if ! online=$(count_cpulist "$list"); then
        log "$LOG_ERR" "error: cannot parse '$list' from $CPU_ONLINE"
        return "$EXIT_ERROR"
    fi

    if (( online == EXPECTED_THREADS )); then
        # Nothing to report; drop a notice left by an earlier run this boot.
        rm -f "$MOTD_FILE" \
            || log "$LOG_ERR" "error: cannot remove the stale login notice $MOTD_FILE"
        log "$LOG_INFO" "$online CPUs online, as expected for mask 0xFF"
        return "$EXIT_OK"
    fi

    if (( online == FACTORY_THREADS )); then
        msg="bc250-8core-unlock: core mask is 0xFF but only $online of $EXPECTED_THREADS CPUs are online. The extra cores appear after the next warm reboot ('systemctl reboot'); powering off restores the factory $FACTORY_CORES cores."
        log "$LOG_WARNING" "warning: $msg"
        notify "$msg"
        return "$EXIT_REBOOT_PENDING"
    fi

    msg="bc250-8core-unlock: core mask is 0xFF but $online CPUs are online ($list); expected $EXPECTED_THREADS, or $FACTORY_THREADS before the first warm reboot. Check the kernel command line (nosmt, maxcpus, nr_cpus) and the ACPI tables."
    log "$LOG_WARNING" "warning: $msg"
    notify "$msg"
    return "$EXIT_UNEXPECTED_COUNT"
}

# set -e does not apply inside a function called from a condition; capture
# the status explicitly so each path exits with its own code.
status=0
main || status=$?
exit "$status"
