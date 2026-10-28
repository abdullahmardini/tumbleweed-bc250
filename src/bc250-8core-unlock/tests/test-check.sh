#!/usr/bin/bash
# Exercise bc250-8core-check against fake cpulists. $1 = script under test.
set -euo pipefail
CHECK=$1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
run() {  # name cpulist expected_status expect_motd(yes/no) [journal]
    local name=$1 list=$2 want=$3 motd=$4 journal=${5:-} got=0 err
    printf '%s\n' "$list" >"$T/online"
    rm -rf "$T/motd.d"
    err=$(env -u JOURNAL_STREAM ${journal:+JOURNAL_STREAM=8:1} BC250_CPU_ONLINE="$T/online" BC250_MOTD_FILE="$T/motd.d/notice" "$CHECK" 2>&1) || got=$?
    local has=no; [[ -e $T/motd.d/notice ]] && has=yes
    if [[ $got == "$want" && $has == "$motd" ]]; then r=PASS; else r=FAIL; fail=1; fi
    printf '%s %-28s list=%-12s exit=%s motd=%s | %s\n' "$r" "$name" "$list" "$got" "$has" "$err"
}
run warm-unlocked       0-15        0 no
run cold-just-set       0-11        2 yes
# journal priority is tested under systemd-run (see report)
run nosmt               0-7         3 yes
run gap-14              0-5,8-15    3 yes
run single              0           3 yes
run garbage             abc         1 no
run reversed-range      5-3         1 no
run empty               ''          1 no
# missing file
got=0; BC250_CPU_ONLINE=$T/nope BC250_MOTD_FILE=$T/m "$CHECK" 2>/dev/null || got=$?
if [[ $got == 1 ]]; then echo "PASS missing-file exit=1"; else echo "FAIL missing-file exit=$got"; fail=1; fi
# stale notice removed on a good count
mkdir -p "$T/motd.d"; echo old >"$T/motd.d/notice"; echo 0-15 >"$T/online"
BC250_CPU_ONLINE=$T/online BC250_MOTD_FILE=$T/motd.d/notice "$CHECK" 2>/dev/null
if [[ ! -e $T/motd.d/notice ]]; then echo "PASS stale-notice-removed"; else echo FAIL stale-notice; fail=1; fi
# unwritable motd location still exits 2
echo 0-11 >"$T/online"; got=0
BC250_CPU_ONLINE=$T/online BC250_MOTD_FILE=/proc/nope/notice "$CHECK" 2>"$T/err" || got=$?
if [[ $got == 2 ]] && grep -q "cannot write" "$T/err"; then echo "PASS motd-unwritable exit=2"; else echo "FAIL motd-unwritable exit=$got"; fail=1; fi
exit $fail
