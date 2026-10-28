#!/bin/bash
# Success- and failure-path tests for bc250-telemetry-log against a fake sysfs/procfs.
# shellcheck disable=SC2015,SC2012 # terse test assertions
set -euo pipefail
T=$(cd "$(dirname "$0")" && pwd)
# Usage: run-tests.sh [logger script] [work dir]
LOG=${1:-$T/bc250-telemetry-log.sh}
W=${2:-$T/work}
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
run() { # root outdir samples [env...] ; sets RC, ERR
    local root=$1 out=$2 n=$3; shift 3
    set +e
    ERR=$(env -u JOURNAL_STREAM BC250_TELEMETRY_SYSFS="$root/sys" BC250_TELEMETRY_PROC="$root/proc" \
        BC250_TELEMETRY_DIR="$out" BC250_TELEMETRY_INTERVAL=1 BC250_TELEMETRY_SAMPLES="$n" "$@" \
        bash "$LOG" 2>&1 >/dev/null)
    RC=$?
    set -e
}
col() { # file column-name row(2..) -> value
    awk -F, -v c="$2" -v r="$3" 'NR==1{for(i=1;i<=NF;i++) if($i==c) k=i} NR==r{print $k}' "$1"
}
rm -rf "$W"; mkdir -p "$W"
today=$(date +%F)

# 1. full fake tree, overlay present
bash "$T/bc250-telemetry-log-mkfake.sh" "$W/f"
run "$W/f" "$W/o1" 2
f=$W/o1/telemetry-$today.csv
[[ $RC == 0 ]] && ok "full tree exits 0" || bad "full tree rc=$RC $ERR"
[[ $(wc -l <"$f") == 3 ]] && ok "header + 2 rows" || bad "line count $(wc -l <"$f")"
[[ $(col "$f" gpu_metrics_src 2) == overlay ]] && ok "overlay detected" || bad "src $(col "$f" gpu_metrics_src 2)"
[[ -n $(col "$f" apu_power_mW 2) ]] && ok "apu_power decoded: $(col "$f" apu_power_mW 2) mW" || bad "apu_power empty"
[[ $(col "$f" nct6686_fan2_rpm 2) == 1400 ]] && ok "nct fan2" || bad "nct fan2"
[[ $(col "$f" nvme0_temp1_composite_mC 2) == 34850 ]] && ok "nvme named by controller" || bad "nvme col"
head -1 "$f" | grep -q amdgpu_power1 && bad "SMU columns present by default" || ok "no SMU-backed columns by default"
grep -q "gpu_busy_percent unreadable" <<<"$ERR" && ok "gpu_busy_percent missing warned" || bad "busy warn: $ERR"
awk -F, 'NR>1 && NF!=n{exit 1} NR==1{n=NF}' "$f" && ok "all rows same field count" || bad "ragged rows"

# 2. hwmon renumbered: same header, same file
mv "$W/f/sys/class/hwmon/hwmon0" "$W/f/sys/class/hwmon/hwmon20"
run "$W/f" "$W/o1" 1
[[ $(ls "$W/o1" | wc -l) == 1 && $(wc -l <"$f") == 4 ]] && ok "renumbered hwmon appends to same file" || bad "renumber made new file: $(ls "$W/o1")"

# 3. missing nct6686 and nvme -> warnings, new file (header differs)
bash "$T/bc250-telemetry-log-mkfake.sh" "$W/g"; rm -rf "$W/g/sys/class/hwmon/hwmon0" "$W/g/sys/class/hwmon/hwmon12"
run "$W/g" "$W/o1" 1
grep -q "expected hwmon 'nct6686' not found.*force=1" <<<"$ERR" && ok "missing nct6686 warned" || bad "nct warn: $ERR"
grep -q "expected hwmon 'nvme' not found" <<<"$ERR" && ok "missing nvme warned" || bad "nvme warn"
[[ $(ls "$W/o1" | wc -l) == 2 ]] && ok "changed header -> second file $(ls "$W/o1" | tail -1)" || bad "files: $(ls "$W/o1")"

# 4. unreadable file -> empty field, warn once, recover
bash "$T/bc250-telemetry-log-mkfake.sh" "$W/h"; chmod 000 "$W/h/sys/class/hwmon/hwmon3/temp1_input"
( sleep 1.5; chmod 644 "$W/h/sys/class/hwmon/hwmon3/temp1_input" ) &
run "$W/h" "$W/o4" 4
wait
f=$W/o4/telemetry-$today.csv
[[ -z $(col "$f" k10temp_temp1_tctl_mC 2) && $(col "$f" k10temp_temp1_tctl_mC 5) == 50000 ]] && ok "unreadable -> empty, then value" || bad "k10 values: $(cut -d, -f17 "$f" | tr '\n' ' ')"
[[ $(grep -c "cannot read .*hwmon3/temp1_input" <<<"$ERR") == 1 ]] && ok "warned once" || bad "warn count: $ERR"
grep -q "hwmon3/temp1_input readable again" <<<"$ERR" && ok "recovery logged" || bad "no recovery msg"

# 5. no overlay (governor stopped / fix-metrics off) -> not read, warned
bash "$T/bc250-telemetry-log-mkfake.sh" "$W/i"; : >"$W/i/proc/self/mountinfo"
run "$W/i" "$W/o5" 2
f=$W/o5/telemetry-$today.csv
[[ $(col "$f" gpu_metrics_src 2) == live && -z $(col "$f" apu_power_mW 2) ]] && ok "live gpu_metrics not read by default" || bad "live: $(sed -n 2p "$f")"
[[ $(grep -c "not the governor's copy" <<<"$ERR") == 1 ]] && ok "live warned once" || bad "live warn: $ERR"
run "$W/i" "$W/o5b" 1 BC250_TELEMETRY_SMU_READS=1
f=$W/o5b/telemetry-$today.csv
[[ -n $(col "$f" apu_power_mW 2) && $(col "$f" pp_dpm_sclk_cur_MHz 2) == 500 && $(col "$f" amdgpu_power1_average_uW 2) == 36000000 ]] && ok "SMU_READS=1 reads live gpu_metrics, hwmon, pp_dpm_sclk" || bad "smu reads: $(head -2 "$f")"
grep -q "SMU_READS=1: each row" <<<"$ERR" && ok "SMU_READS warned" || bad "no smu warn"

# 6. bad gpu_metrics format
bash "$T/bc250-telemetry-log-mkfake.sh" "$W/j"; head -c 64 /dev/zero >"$W/j/sys/devices/pci/0000:01:00.0/gpu_metrics"
run "$W/j" "$W/o6" 1
grep -q "not gpu_metrics v2.2" <<<"$ERR" && ok "bad format warned" || bad "format: $ERR"
f=$W/o6/telemetry-$today.csv
awk -F, 'NR>1 && NF!=n{exit 1} NR==1{n=NF}' "$f" && ok "bad format keeps field count" || bad "ragged"

# 7. no hwmon class, unwritable dir, bad env
mkdir -p "$W/k/sys" "$W/k/proc"
run "$W/k" "$W/o7" 1
[[ $RC == 1 ]] && grep -q "class/hwmon does not exist" <<<"$ERR" && ok "no hwmon -> exit 1" || bad "no hwmon rc=$RC"
mkdir -p "$W/ro"; chmod 555 "$W/ro"
run "$W/f" "$W/ro" 1
[[ $RC == 1 ]] && grep -q "not writable" <<<"$ERR" && ok "unwritable dir -> exit 1" || bad "ro rc=$RC $ERR"
chmod 755 "$W/ro"
run "$W/f" "$W/o7" 1 BC250_TELEMETRY_INTERVAL=abc
[[ $RC == 2 ]] && ok "bad interval -> exit 2" || bad "bad env rc=$RC"

# 8. pruning: old files and size cap
mkdir -p "$W/o8"
old=$(date -d '-60 days' +%F); mid=$(date -d '-10 days' +%F); mid2=$(date -d '-5 days' +%F)
echo x >"$W/o8/telemetry-$old.csv"
truncate -s 100M "$W/o8/telemetry-$mid.csv"; truncate -s 100M "$W/o8/telemetry-$mid2.csv"
echo keep >"$W/o8/notes.txt"
run "$W/f" "$W/o8" 1
[[ ! -e $W/o8/telemetry-$old.csv ]] && ok "file older than KEEP_DAYS removed" || bad "old kept"
[[ ! -e $W/o8/telemetry-$mid.csv && -e $W/o8/telemetry-$mid2.csv ]] && ok "oldest removed to fit cap, newer kept" || bad "cap: $(ls "$W/o8")"
[[ -e $W/o8/notes.txt ]] && ok "foreign files untouched" || bad "notes removed"

# 9. current file deleted mid-run -> header rewritten; SIGTERM -> exit 0 quickly
bash "$T/bc250-telemetry-log-mkfake.sh" "$W/m"
f=$W/o9/telemetry-$today.csv
env -u JOURNAL_STREAM BC250_TELEMETRY_SYSFS="$W/m/sys" BC250_TELEMETRY_PROC="$W/m/proc" BC250_TELEMETRY_DIR="$W/o9" \
    BC250_TELEMETRY_INTERVAL=1 bash "$LOG" 2>/dev/null &
pid=$!
sleep 1.5; rm -f "$f"; sleep 1.2
start=$(date +%s%N); kill -TERM "$pid"; set +e; wait "$pid"; rc=$?; set -e; end=$(date +%s%N)
head -1 "$f" | grep -q '^time,epoch_s' && ok "deleted file gets header back" || bad "no header: $(head -1 "$f")"
[[ $rc == 0 && $(((end - start) / 1000000)) -lt 2000 ]] && ok "SIGTERM exits 0 in $(((end - start) / 1000000)) ms" || bad "TERM rc=$rc"

# 10. amdgpu hwmon missing; gpu_metrics file missing
bash "$T/bc250-telemetry-log-mkfake.sh" "$W/n"; rm -rf "$W/n/sys/class/hwmon/hwmon7"
run "$W/n" "$W/o10" 1
f=$W/o10/telemetry-$today.csv
[[ $RC == 0 && $(col "$f" gpu_metrics_src 2) == missing ]] && grep -q "expected hwmon 'amdgpu' not found" <<<"$ERR" && ok "no amdgpu: warned, src=missing, still logs" || bad "no amdgpu rc=$RC $ERR"
bash "$T/bc250-telemetry-log-mkfake.sh" "$W/p"; rm -f "$W/p/sys/devices/pci/0000:01:00.0/gpu_metrics"
run "$W/p" "$W/o11" 1
f=$W/o11/telemetry-$today.csv
[[ $RC == 0 && $(col "$f" gpu_metrics_src 2) == missing ]] && grep -q "gpu_metrics missing" <<<"$ERR" && ok "no gpu_metrics: warned" || bad "no gm rc=$RC $ERR"

echo "passed $pass, failed $fail"
((fail == 0))
