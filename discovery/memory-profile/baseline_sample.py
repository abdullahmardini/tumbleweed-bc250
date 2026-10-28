#!/usr/bin/env python3
"""Read-only idle baseline: sysfs clocks, hwmon PPT, gpu_metrics fields. No SMU access of our own."""
import glob, struct, time, statistics, sys
DEV = "/sys/class/drm/card1/device"
# hwmon numbering shifts with module load order; the GPU device has exactly one.
HWMON = glob.glob(DEV + "/hwmon/hwmon*")[0]
SAMPLES = int(sys.argv[1]) if len(sys.argv) > 1 else 24
INTERVAL_S = 5.0
# gpu_metrics_v2_2 offsets (kgd_pp_interface.h)
OFF = {"socket_mw?": 0x28, "soc_power": 0x2C, "gfx_power": 0x2E, "avg_uclk": 0x44, "avg_fclk": 0x46, "cur_uclk": 0x50, "cur_fclk": 0x52, "cur_socclk": 0x4E}
def mhz(path):
    for line in open(path):
        if "*" in line:
            return int(line.split(":")[1].strip().split("Mhz")[0])
    return None
rows = []
for i in range(SAMPLES):
    gm = open(DEV + "/gpu_metrics", "rb").read()
    r = {k: struct.unpack_from("<H", gm, o)[0] for k, o in OFF.items()}
    r["mclk"] = mhz(DEV + "/pp_dpm_mclk"); r["fclk"] = mhz(DEV + "/pp_dpm_fclk")
    r["ppt_in_W"] = int(open(HWMON + "/power1_input").read()) / 1e6
    r["ppt_avg_W"] = int(open(HWMON + "/power1_average").read()) / 1e6
    r["load1"] = float(open("/proc/loadavg").read().split()[0])
    rows.append(r)
    print(time.strftime("%H:%M:%S"), r, flush=True)
    if i < SAMPLES - 1:
        time.sleep(INTERVAL_S)
print("MEAN", {k: round(statistics.mean(r[k] for r in rows), 2) for k in rows[0]})
print("MIN ", {k: min(r[k] for r in rows) for k in rows[0]})
print("MAX ", {k: max(r[k] for r in rows) for k in rows[0]})
