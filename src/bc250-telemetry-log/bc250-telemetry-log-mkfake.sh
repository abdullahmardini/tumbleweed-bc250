#!/bin/bash
# bc250-telemetry-log-mkfake.sh ROOT: fake sysfs + procfs for bc250-telemetry-log tests.
set -euo pipefail
R=$1
rm -rf "$R"; mkdir -p "$R/sys/class/hwmon" "$R/sys/devices/pci/0000:01:00.0" "$R/sys/devices/nvme0" "$R/proc/self"
mk() { d=$R/sys/class/hwmon/$1; mkdir -p "$d"; echo "$2" >"$d/name"; }
mk hwmon7 amdgpu; ln -s ../../../devices/pci/0000:01:00.0 "$R/sys/class/hwmon/hwmon7/device"
echo 47000 >"$R/sys/class/hwmon/hwmon7/temp1_input"; echo 36000000 >"$R/sys/class/hwmon/hwmon7/power1_average"; echo 99000000 >"$R/sys/class/hwmon/hwmon7/freq1_input"
printf '0: 1000Mhz \n1: 500Mhz *\n2: 2000Mhz \n' >"$R/sys/devices/pci/0000:01:00.0/pp_dpm_sclk"
# gpu_metrics v2.2 captured on the BC-250 (2026-10-28, governor overlay).
GM_HEX=8000020218159a1093070000e70a00002517b518ffffffffc71570170000ffffd5628feb980200000adeffffc25dc9193ad78209d4080009970b0f09ffffffff0a01e604c201c201000057046400e604c201c20100005704ac0dac0dac0dac0dac0dac0dffffffffac0dac0d00000000ffffffffffffffffffffffffffffffff
gm=
for ((i = 0; i < ${#GM_HEX}; i += 2)); do gm+="\\x${GM_HEX:i:2}"; done
printf %b "$gm" >"$R/sys/devices/pci/0000:01:00.0/gpu_metrics"
mk hwmon3 k10temp; echo 50000 >"$R/sys/class/hwmon/hwmon3/temp1_input"; echo Tctl >"$R/sys/class/hwmon/hwmon3/temp1_label"
mk hwmon12 nvme; ln -s ../../../devices/nvme0 "$R/sys/class/hwmon/hwmon12/device"
echo 34850 >"$R/sys/class/hwmon/hwmon12/temp1_input"; echo Composite >"$R/sys/class/hwmon/hwmon12/temp1_label"
mk hwmon0 nct6686
for i in 1 2; do echo "${i}0000" >"$R/sys/class/hwmon/hwmon0/temp${i}_input"; echo $((i*700)) >"$R/sys/class/hwmon/hwmon0/fan${i}_input"; echo 178 >"$R/sys/class/hwmon/hwmon0/pwm$i"; done
echo "AMD TSI Addr 98h" >"$R/sys/class/hwmon/hwmon0/temp1_label"
cp /proc/uptime "$R/proc/uptime"
echo "181 49 0:29 /patched_gpu_metrics//deleted /sys/devices/pci/0000:01:00.0/gpu_metrics rw - tmpfs tmpfs rw" >"$R/proc/self/mountinfo"
