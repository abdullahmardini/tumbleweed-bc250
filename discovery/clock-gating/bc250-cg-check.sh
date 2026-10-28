#!/bin/bash
# Read-only check of BC-250 GFX clock-gating state plus an idle PPT sample.
# Run it once on the stock boot (baseline) and once on the bc250_cg boot,
# with the same desktop state (close FurMark/benchmarks, no osc builds).
# Writes nothing to /sys; the only root access is `sudo cat amdgpu_pm_info`.
set -euo pipefail

readonly CARD=/sys/class/drm/card1/device
readonly PM_INFO=/sys/kernel/debug/dri/1/amdgpu_pm_info
readonly PARAM=/sys/module/amdgpu/parameters/bc250_cg
readonly SAMPLES=60          # 60 x 5 s = 5 min: averages out desktop wakeups
readonly INTERVAL_S=5
readonly MAX_IDLE_LOAD=1.0   # 1-min loadavg above this makes PPT not an idle number
readonly UW_PER_W=1000000
readonly MC_PER_C=1000

hwmon=$(ls -d "$CARD"/hwmon/hwmon*)
[[ -r $hwmon/power1_average ]] || { echo "no PPT sensor under $hwmon" >&2; exit 1; }

echo "== boot: $(uname -r), cmdline amdgpu params: $(tr ' ' '\n' </proc/cmdline | grep '^amdgpu\.' || echo none)"
if [[ -r $PARAM ]]; then
	echo "== amdgpu.bc250_cg = $(cat "$PARAM")"
else
	echo "== amdgpu.bc250_cg not present: the loaded amdgpu.ko is not the CG build"
fi
echo "== kernel log (bc250-cg / 40cu / gfx errors):"
journalctl -k -b --no-pager | grep -E 'bc250-cg|bc250-40cu-enable|ring .* timeout|GPU reset|RLC|gfx_v10' || echo "  (no matching lines)"

echo "== GFX clock-gating flags (amdgpu_pm_info):"
sudo cat "$PM_INFO" | grep -E 'Clock Gating Flags Mask|Graphics (Medium|Coarse) Grain Clock Gating|SoC including CPU|SCLK|VDDGFX'

load1=$(cut -d' ' -f1 /proc/loadavg)
if awk -v l="$load1" -v m="$MAX_IDLE_LOAD" 'BEGIN{exit !(l>m)}'; then
	echo "WARNING: loadavg $load1 > $MAX_IDLE_LOAD; PPT below is not an idle baseline" >&2
fi

echo "== sampling PPT/edge for $((SAMPLES * INTERVAL_S)) s"
sum_uw=0; min_uw=; max_uw=0
for ((i = 0; i < SAMPLES; i++)); do
	uw=$(cat "$hwmon"/power1_average)
	sum_uw=$((sum_uw + uw))
	((uw > max_uw)) && max_uw=$uw
	[[ -z $min_uw || $uw -lt $min_uw ]] && min_uw=$uw
	sleep "$INTERVAL_S"
done
temp_mc=$(cat "$hwmon"/temp1_input)
awk -v s="$sum_uw" -v n="$SAMPLES" -v lo="$min_uw" -v hi="$max_uw" -v t="$temp_mc" \
	-v w="$UW_PER_W" -v c="$MC_PER_C" -v l="$(cut -d' ' -f1 /proc/loadavg)" \
	'BEGIN{printf "PPT mean %.2f W (min %.2f, max %.2f), edge %d C, loadavg %s\n", s/n/w, lo/w, hi/w, t/c, l}'
