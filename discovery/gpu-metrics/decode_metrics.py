"""Decode amdgpu gpu_metrics v2.2 (Cyan Skillfish) and reinterpret the
Current-table-derived fields under the 8-core hybrid layout from
higorprado's 0001-bc250-8core-telemetry.patch. Read-only."""
import struct, sys, time
PATH = sys.argv[1]
N = int(sys.argv[2]); GAP = float(sys.argv[3])
# struct gpu_metrics_v2_2, kgd_pp_interface.h (7.3), natural alignment
FMT = "<HBB" "HH8H2H" "HH" "Q" "HHHH8H" "6H" "6H8H2H" "I" "H3H" "Q"
names = (["size","fmt","content","t_gfx","t_soc"]+[f"t_core{i}" for i in range(8)]+["t_l3_0","t_l3_1",
 "gfx_act","mm_act","clock_ns","p_socket","p_cpu","p_soc","p_gfx"]+[f"p_core{i}" for i in range(8)]+
 ["avg_gfxclk","avg_socclk","avg_uclk","avg_fclk","avg_vclk","avg_dclk",
  "cur_gfxclk","cur_socclk","cur_uclk","cur_fclk","cur_vclk","cur_dclk"]+[f"clk_core{i}" for i in range(8)]+
 ["l3clk0","l3clk1","throttle","fan_pwm","pad0","pad1","pad2","indep_throttle"])
assert struct.calcsize(FMT) == 128, struct.calcsize(FMT)
for s in range(N):
    raw = open(PATH, "rb").read()
    v = dict(zip(names, struct.unpack(FMT, raw[:128])))
    h = lambda x: "----" if x == 0xFFFF else str(x)
    print(f"--- sample {s} len={len(raw)} size={v['size']} format={v['fmt']}.{v['content']} clock_ns={v['clock_ns']}")
    print("  t_core  :", [h(v[f't_core{i}']) for i in range(8)])
    print("  p_core  :", [h(v[f'p_core{i}']) for i in range(8)])
    print("  clk_core:", [h(v[f'clk_core{i}']) for i in range(8)])
    print(f"  t_gfx={v['t_gfx']} t_soc={v['t_soc']} t_l3={v['t_l3_0']},{v['t_l3_1']} l3clk={v['l3clk0']},{v['l3clk1']}")
    print(f"  cur_gfxclk={v['cur_gfxclk']} avg_gfxclk={v['avg_gfxclk']} cur_socclk={v['cur_socclk']} cur_uclk={v['cur_uclk']} gfx_act={v['gfx_act']}")
    print(f"  p_socket={v['p_socket']} p_cpu={h(v['p_cpu'])} p_soc(VDD)={v['p_soc']} p_gfx={v['p_gfx']} throttle={v['throttle']:#x}")
    # Reinterpret under the hybrid layout. Stock driver copies Current bytes
    # 0x24..0x2F (stock CoreTemperature[0..5]) into t_core0..5; in the hybrid
    # layout those bytes are CorePower[5] (core 6, u32), CorePower[6] (core 7,
    # u32), CoreTemperature[0..1] (cores 4,5).
    p6 = v['t_core0'] | (v['t_core1'] << 16); p7 = v['t_core2'] | (v['t_core3'] << 16)
    print(f"  hybrid view: core6_power_mW={p6} core7_power_mW={p7} core4_temp={v['t_core4']} core5_temp={v['t_core5']} cur_gfxclk(=C0Residency[6])={v['cur_gfxclk']}")
    if s + 1 < N: time.sleep(GAP)
