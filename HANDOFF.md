# BC-250 handoff

Status: packages built in `home:superppl:bc250` and installed from the `bc250` repo (2026-10-25 18:53). `bc250-40cu` retired 2026-10-26 and removed from the host by `zypper dup` (`bc250-setup` 0.2.0). 40 CU verified 2026-10-25 21:19 with `bc250-amdgpu-kmp-default` r2: mode 3, four `bc250-40cu-enable` lines `CC=0xfff80000->0xffe00000 SPI=0x00000007->0x0000001f`, `active_cu_number 40`, RADV `num_cu = 40`. Governor 500-1850 MHz, active. BIOS is P3.00 Chipset Menu with a 512 MB VRAM split. 8 cores / 16 threads verified 2026-10-25 19:48. Before the boot that started 2026-10-25 after 23:12, the user cleared CMOS with the jumper by accident: SVM is back to off, the VRAM split still reads 512 MiB, and the board cold-booted on 6 cores (checked 2026-10-27).
Goal: run the BC-250 on openSUSE Tumbleweed with packages built in the openSUSE Build Service (OBS), contributing upstream where AI contributions are accepted.

## Decision

Option 3: a small OBS project plus one `bc250-setup` meta RPM. Setting up a host is `zypper ar` + `zypper in bc250-setup`; `zypper dup` keeps it current.

- One package per piece: governor, `umr` (debug tool, nothing requires it), the 40 CU `amdgpu` KMP, ACPI tables, the 8-core script.
- `bc250-setup` depends on them. It ships the sensor config, the suspend block and a systemd preset. Its only scriptlet is one `systemctl preset` on first install: the unit packages install first and preset their units before the preset file exists.
- The preset enables the governor and the 8-core unit. `bc250-setup` does not pull in the KMP. `bc250-setup` 0.2.0 has `Obsoletes: bc250-40cu <= 0.1.0` and `Provides: bc250-40cu = 0.2.0`, so `zypper up`/`dup` removes the retired runtime package. Installing the KMP enables 40 CU: it ships `options amdgpu bc250_cc_write_mode=3` in `/usr/lib/modprobe.d/50-bc250-40cu.conf`. The governor package (r3) ships `min = 500`, `max = 1850` in its `%config(noreplace)` default (upstream: 1000-1850); its `%prep` fails if upstream changes those lines. Ceiling 1850 is the user's decision (2026-10-26) from the heat-soaked Superposition run. An edited `/etc` config is kept and the new default lands as `.rpmnew`.
- Per-board values (voltage curve, CU layout) stay in this repo.

Build order. Each step is usable on its own; finish one before starting the next.

1. Governor RPM, installed with `zypper` and running.
2. `umr` package and the 40 CU KMP (`bc250-amdgpu`), governor 500-1850 MHz.
3. Sensor config, ACPI tables, `bc250-setup`.
4. Package the 8-core script.
5. Upstream contributions, after asking each maintainer about AI-assisted PRs.

## Rejected

| Option | Why rejected |
| --- | --- |
| 1. Governor RPM only, rest by hand | Only the governor updates; the rest drifts. It survives only as step 1 of the build order. |
| 2. OBS packages, configs copied by hand | Setup stays a manual checklist. Option 3 is the same packages plus the meta RPM. |
| 4. Upstream-first (Factory, devel projects) | Slow review loops before anything runs. Deferred to step 5. |
| 5. No RPMs, upstream tarballs and scripts | Nothing updates on its own. |
| 40 CU via DKMS or a patched `kernel-default` | DKMS compiles on the host. A patched `kernel-default` in OBS means maintaining a kernel. Chosen instead: a KMP that rebuilds only `amdgpu` from `kernel-source` in OBS (`bc250-amdgpu`); OBS rebuilds it when the kernel changes. |
| Shipping WinnieLV's live manager | No license. |
| Runtime 40 CU through `umr` (`bc250-40cu`, retired 2026-10-26) | `gfx_v10_0_get_cu_info()` reads `CC_GC_SHADER_ARRAY_CONFIG` only in hw_init and caches it in `adev->gfx.cu_info`, which the DEV_INFO ioctl (RADV) and KFD return (7.3.0-1.1: gfx_v10_0.c:5350/10090, amdgpu_kms.c:1010, kfd_crat.c:2304). Writes after init leave 24 CUs reported. duggasco's state 2 (SPI `0x1F`, stock enumeration) gave no gain. elektricm and WinnieLV call the runtime route working but publish no benchmark. The KMP does CC, SPI and RLC at init. |
| Masking sleep targets from a package | `/etc` is admin territory. A `sleep.conf.d` drop-in in `/usr/lib` does the same and can be overridden. |

## The pieces

| Piece | What it is | Package |
| --- | --- | --- |
| Governor | GPU clocks and voltage, the main GPU power saving | `cyan-skillfish-governor-smu` |
| 40 CU | CC/SPI/RLC writes in `amdgpu` init, behind `amdgpu.bc250_cc_write_mode=3` | `bc250-amdgpu-kmp-default` |
| 8-core | SMU message `0x98` sets the core mask | `bc250-8core-unlock` |
| Sensors | Reading only needs `options nct6683 force=1`. `nct6687` is only for software fan curves. | Config in `bc250-setup`; `bc250-nct6687-kmp-default` (not loaded by anything yet) |
| Power | CPU idle and frequency states come from ACPI tables. The governor covers the GPU; its voltage curve is the undervolt. | `bc250-acpi-tables` |
| Suspend | Disabled: s2idle resume is unreliable and saves almost no power | Config in `bc250-setup` |

## OBS packages (`home:superppl:bc250`, built 2026-10-26)

| Package | Source | Notes |
| --- | --- | --- |
| `cyan-skillfish-governor-smu` | tag v0.4.14 (`7b08fdc`), crates vendored with `cargo_vendor` | 37 tests pass in `%check`. Carries `dbus-policy-scope-to-destination.patch` (below). rpmlint `dbus-file-unauthorized` stays until the SUSE security team whitelists the policy; that only matters for Factory. |
| `umr` | `osc linkpac hardware umr` (1.0.11, MIT) | 1.0.11 has `cyan_skillfish.asic` and all three 40 CU registers in `gc_10_1_0.reg`. Nothing requires it since `bc250-40cu` was retired; kept to read CC/SPI per SE/SH. |
| `bc250-8core-unlock` | GabriWar commit `c532536`, script and LICENSE only, plus `bc250-8core-unlock-fail-on-refusal.patch` | The upstream tree also ships BIOS images, so the archive is not used. The patch makes `boot` exit 1 on every refusal and failure (unexpected mask, SMN read or mailbox error, unlock not taking) and refuses a 00:00.0 that is not `1022:13e0` before any register access. Our unit runs `boot` `Before=` the governor, ordering only (no `Requires=`): a failure shows in `systemctl --failed` and does not stop the governor. r2 (2026-10-26) built; exit codes tested against a fake `setpci` only. r3 (2026-10-28, built locally, not committed): `bc250-8core-check` runs as `ExecStartPost=-` and counts online CPUs. 16: quiet. 12: journal warning, `/run/motd.d/bc250-8core-unlock` login notice (pam_motd: console and sshd), exit 2, shown on the ExecStartPost line of `systemctl status` without failing the unit. Other counts: warning, exit 3. Tested against fake inputs and a user transient unit; not yet seen at a real cold boot. |
| `bc250-acpi-tables` | e-tho/bc250-acpi-fix v1.1.1, built with `iasl` | Drop-in `/usr/lib/dracut/dracut.conf.d/50-bc250-acpi.conf` sets `acpi_override` and `acpi_table_dir`. `%regenerate_initrd_post` rebuilds the initrd; suse-module-tools' posttrans calls `sdbootutil` on systemd-boot, so no loader entry edits. Covers all 16 processor objects, so the same tables serve stock and unlocked boards (stock DSDT declares P000-P00F on BIOS 1.00-5.00; stock MADT marks the extra 4 disabled, per the lorek123 dump). `%check` fails the build if any P000-P00F lacks its methods (r2). mendesrr's 8-core fork is not used: no license, it publishes C3 (e-tho reverted C3 in `25b4153` for freezes), and its `_PSD` puts all CPUs in one domain. e-tho credits mendesrr's 8-core extension. |
| `bc250-setup` | `src/bc250-setup/` | 0.2.0: preset enables the governor and 8-core; `Obsoletes`/`Provides` `bc250-40cu`. The offline `systemctl --root` preset check was done on 0.1.0. |
| `bc250-amdgpu` → `bc250-amdgpu-kmp-default` | duggasco `ae7c30c` patch, rebased onto 7.3 in `src/bc250-amdgpu/`; `drivers/gpu/drm/amd` from `kernel-source` 7.3.0-1.1 | Builds only `amdgpu.ko` with `M=` against `linux-obj`, installs to `updates/` (depmod searches it first). `%prep` uses `patch --fuzz=0`, so a moved hunk fails the build; the unrebased patch fails with `Hunk #2 FAILED`. `%build` checks `modinfo` for the parameter and that vermagic is `7.3.0-1-default`. All 1156 `ksym()` requires match the installed `kernel-default` 7.3.0-1.1; firmware list (725) and `depends` equal the in-tree module. `-b` rebuilds the initrd on install. Module is unsigned (taints, loads: `MODULE_SIG_FORCE` off). Ships `/usr/lib/modprobe.d/50-bc250-40cu.conf` with mode 3 enabled; dracut `80base` copies `/usr/lib/modprobe.d/*.conf` into the initrd. |
| `bc250-nct6687` → `bc250-nct6687-kmp-default` | Fred78290/nct6687d `ec1030b` (GPL-2.0) | r1 committed 2026-10-28, OBS build succeeded (`0~git20261019.ec1030b_k7.3.0_1-1.1`). Same KMP pattern as `bc250-amdgpu` without `-b`: `%build` checks the `force` parm and vermagic. Ships `options nct6687 force=1` in `/usr/lib/modprobe.d/50-bc250-nct6687.conf`. No alias, so nothing loads it; it cannot bind while `nct6683` holds the chip. rpmlint: `suse-zypp-packageand` (macro), `no-%check-section`. Tested from a local build, see Sensors. |

## 8-core

Verified 2026-10-25 19:48, after a warm reboot: `nproc` 16, `Core(s) per socket: 8`, unit logs `already unlocked (0xFF  enabled=[0 1 2 3 4 5 6 7] disabled=[])`. On this P3.00 board the mask accepted `0xFF` (not the `0x7D` case from issue #1).

Checked 2026-10-25 19:02, read-only (no journal or SMN access):

- `bc250-8core-unlock.service` and the governor are enabled by the preset. The RPM was installed at 18:53 and its unit only starts at boot, so the boot at 18:58 is the first time it ran. `boot` only acts on 0x77, and it logged `mask set to 0xFF`, so this board's factory mask was 0x77. 00:00.0 is `1022:13e0` (Ariel Root Complex). Since package r2, exit 0 means the mask reads 0xFF Verified with r2 on the 21:19 boot: exit 0, `already unlocked (0xFF …)`.
- Each boot the unit sets the mask; the cores only appear after the *next* warm reboot. One soft reboot after install cannot show 8 cores.
- After a cold boot the unit logs `mask set to 0xFF -- all 8 cores will appear on your next reboot` and exits 0 with 6 cores online (2026-10-27). Nothing flags the missing cores; `nproc` 12 is the check. `bc250-8core-unlock` r3 adds a warning (package table), not installed yet.
- `present` = `possible` = `0-11`, no `nr_cpus`/`maxcpus` on the cmdline. `/sys/kernel/reboot/mode` is `cold`, type `acpi`. MADT (`APIC`, 222 bytes) and the kernel log need root.
- Upstream issue #1: on the same `BC250_3.00_CHIPSETMENU.ROM`, the mask reads `0x7D` (cores 1 and 7 off), and the unit logs `unexpected mask 0x7D, not touching anything`. Unmerged PR #2 accepts any mask with one core off per 4-core cluster. Its hardware-test sections are unfilled placeholders, so there is no published evidence a 0x7D board unlocked. Not adopted: it widens what the script acts on without evidence, and this board is 0x77.
- ACPI tables cover all 16 threads (verified 2026-10-25, read-only): e-tho v1.1.1 scopes `\_PR.P000`-`P00F` in SSDT-CPU and SSDT-PST (`iasl -d`). Loaded SSDT1/3/4 are 1019/1339/60 bytes, the same as `/usr/lib/bc250-acpi/*.aml`. CPUs 0-15 have `acpi_idle` POLL/C1/C2 (C2 `ACPI IOPORT 0x414`) and `acpi-cpufreq`, 8 steps 800 MHz to 3.2 GHz. cpuN has apicid N and firmware node `\_PR_.P00N`; siblings (2k, 2k+1) match the per-core `_CSD`/`_PSD`.

## 40 CU

`umr` is AMD's User Mode Register debugger (`tomstdenis/umr` on freedesktop GitLab). It reads and writes `amdgpu` registers through debugfs (`/sys/kernel/debug/dri/<N>/`), needs root, and is ordinary userspace C, so it does not track the kernel.

Registers, per shader array (SE0-1 × SH0-1), from duggasco's technical report:

| Register | Stock | Unlocked | Role |
| --- | --- | --- | --- |
| `CC_GC_SHADER_ARRAY_CONFIG` | `0xfff80000` | `0xffe00000` | Enumeration: how many CUs the driver reports |
| `SPI_PG_ENABLE_STATIC_WGP_MASK` | `0x7` | `0x1f` | Dispatch gate: which WGPs receive waves |
| `RLC_PG_ALWAYS_ON_WGP_MASK` (global) | | `0x1f` | Set alongside SPI by duggasco and WinnieLV |

**Route: the init-time patched module (`bc250-amdgpu`).** In the 7.3 source, `gfx_v10_0_get_cu_info()` is called from `gfx_v10_0_constants_init()` in `gfx_v10_0_hw_init()` (also run on resume and GPU reset). It reads `CC_GC_SHADER_ARRAY_CONFIG` there and caches the CU count and bitmaps that RADV and KFD see. The patch writes CC, SPI and RLC just before that read, so the writes are redone on every hw_init. duggasco's 4-state test shows SPI `0x1f` with stock enumeration gives no compute gain (302 → 302 tok/s); the 1.61× needs both. All published speedups use the patched module.

The runtime route is rejected; see Rejected.

The writes are MMIO from the driver, not the SMU mailbox, so they do not contend with the governor.

Performance, from the elektricm 40 CU page (duggasco A/B/A test, patched kernel, stock cooler); not measured on this board:

- **Compute:** Vulkan `llama-bench` pp512 at 1500 MHz, 230 → 372 tok/s (1.61×, theoretical 1.67×), 95 → 125 W, 79 → 83 °C.
- **Graphics:** the page's only number is `glmark2` +4.4%, and it says graphics is not widely tested. glmark2 is CPU/driver-bound, so it understates gaming. YouTube game benchmarks (reported by the user, not linked) show about +30%.
- **Thermals at 2 GHz, sustained:** CPU 100 °C (TJmax), PPT peak 220-230 W, GPU edge peak 107 °C, throttles within minutes. The page recommends 1500 MHz / 900 mV. Run the governor before unlocking.

Measured on this board (reported by the user, 2026-10-25):

| Benchmark | Config | Runs | Average |
| --- | --- | --- | --- |
| Unigine Superposition 1080p Extreme | Stock 24 CU, 6 cores, governor active, BIOS P3.00, kernel 7.3.0-1, Mesa 26.2.5 | 3164, 3190, 3191 | 3182 |
| Unigine Superposition 1080p Extreme | 24 CU, 8 cores, governor active, fan curves changed by the user | 3775, 3787, 3733 | 3765 (+18%) |
| Unigine Superposition 1080p Extreme | 40 CU, 8 cores, governor max 1500 MHz, fan curves changed | 4124, 4128, 4125 | 4126 (+30% vs stock, +10% vs 8-core) |
| Unigine Superposition 1080p Extreme | 40 CU, 8 cores, governor 500-1850 MHz (930 mV safe point), fan curves changed, after a FurMark + s-tui heat soak | 4887, 4893, 4888 | 4889 (+54% vs stock, +18% vs 1500 MHz) |

The +18% has two changes at once (8 cores and fan curves). The user believes the stock run did not throttle, but this is unverified: no clocks or temperatures were logged during either run. The 40 CU row also lowers the governor max from 1850 to 1500 MHz; the 8-core run was at 1850. The 1850 MHz run logged no temperatures or clocks either, so whether it throttled (governor at 85 °C GPU edge, CPU at Tctl 100 °C) is unknown; the package ships `max = 1850` anyway (user's decision); a logged run (`bench-log.py`-style: clocks, edge, Tctl) is still the check.

## Suspend

Verified on this board (2026-10-25; journals read with the user in `systemd-journal`):

- `/sys/power/mem_sleep` offers only `[s2idle]`. The DSDT (same on BIOS 1.00-5.00, public dump in lorek123/bc250-notes) has `_S0`, `_S4`, `_S5`, no `_S3`, and no LPS0 device (`PNP0D80`).
- **s2idle has resumed once and hung once.** 2026-10-24 (P2.00, stock tables, 12 threads): `PM: suspend entry (s2idle)` 21:55:19, `PM: suspend exit` 08:09:06; that boot then ends at 08:10:07 with no shutdown sequence (hang or forced power-off, unknown). 2026-10-25 16:32:05 (P3.00, stock tables, 12 threads): entry, no exit. Wake source unknown (`pm_debug_messages` was 0).
- **s2idle saves almost nothing here.** amdgpu never suspends: its only line is `BIOS has not been configured for suspend-to-idle` (no FADT `LOW_POWER_S0`). No S0i3 is possible: no LPS0 device, and `amd_pmc` does not match root complex `1022:13e0`. CPUs reach at most C2 (with the ACPI tables).
- `amd-s2idle` 0.2.22 report (2026-10-25, `idle-report/`, not committed: holds monitor serials): "does not meet s2idle prerequisites". Fails: FADT has no Low-power S0 idle bit, `amd_pmc` binds to no ACPI device, `pinctrl_amd` not loaded (no AMD GPIO device in the DSDT). Kernel logs `ACPI: PM: (supports S0 S4 S5)`. Its "LPS0 _DSM enabled" pass only means not disabled on the cmdline; there is no LPS0 device. Firmware gap, not a driver bug: no kernel change gives S0i3 or S3 here.
- Wake-capable: fixed power button, RTC (`rtc_cmos`), USB/PCIe GPEs per `/proc/acpi/wakeup`. All USB root hubs have `power/wakeup` = `disabled`, so a USB keyboard probably cannot wake it (from `ohci-hub.c`, not tested).
- `pm_test` on s2idle only supports `freezer`, `devices`, `platform` (none enters the idle loop, so none tests wake). The decisive test is `rtcwake -m freeze -s 60` at the console, ready to cut power. Not run.
- **Hibernate:** `_S4` present, `/sys/power/disk` is `[platform]`, `CONFIG_HIBERNATION=y`. Blocked: swap LV `system/swap` is 2 GiB for 14 GiB RAM (the 15 GiB `zram0` cannot hold a hibernation image), and the 8-core unlock is lost on power-off, so the resume boot would have 12 CPUs. Not tested.
- The P5clv ROM setup has an "ACPI Sleep State" (S1/S3/Suspend Disabled) option; the ROM DSDT has no `_S3`, so it probably cannot add S3. Not tested.
- Community: elektricm says resume is unreliable and on some boards the power button wakes it (PR #55). SkillFishOS disables all sleep.
- GNOME's default idle action on AC is `suspend` after 900 s; both recorded attempts were this. `bc250-setup` ships `AllowSuspend=no` / `AllowHibernation=no`, so logind reports `CanSuspend=na` and GNOME stops offering it.

## Sensors

Verified on this board (2026-10-25, with `bc250-setup` installed):

- hwmon: `nct6686` (via `nct6683`), `amdgpu`, `k10temp`, `nvme`.
- **No RAPL.** The CPU has the `rapl` flag, but the kernel logs `RAPL PMU: API unit is 2^-32 Joules, 0 fixed counters`; the `power`/`power_core` PMUs have no events and `/sys/class/powercap` is empty. `sudo turbostat --quiet --interval 5 -n 3 --show CPU,Busy%,PkgWatt,CorWatt` prints no PkgWatt or CorWatt column (2026-10-27).
- **CPU rail power is in `gpu_metrics`** (format 2.2, 128 bytes, world-readable). `average_soc_power` (offset 0x2C) is SMU `Power[0]`, which the firmware header `smu11_driver_if_cyan_skillfish.h` labels VDDCR_VDD, the CPU core rail; `average_gfx_power` (0x2E) is VDDCR_GFX. Per-core power and temperature fields are invalid on the 8-core board. The governor bind-mounts a copy that patches only gfx activity (0x1C-0x1D). hwmon `vddnb` is the VDDCR_VDD voltage; hwmon `sclk` is wrong on 8-core boards (governor README).
- Board PMICs per mothenjoyer69 `hardware.md`: ISL69247, ISL95712, ISL99360. The ISL69247 (PMBus `0x60`) is on a bus separate from the FCH SMBus; reading it needs two jumper wires, `I2C_HEADER1` SCL/SDA to `TPMS1` pins 4/6 (onlinermm/BC250-Telemetry `hardware.md`). The host's I2C buses are AMDGPU DM 0-3 and PIIX4 ports 0-4 only (2026-10-27). `bc250_vrm`/`bc250-vrm-dkms` register an hwmon only on a modded board. No nct6686 channel is a 12 V input or current sense.
- **VRAM temperature works with pan-Rijovich's tool, one-shot** (2026-10-28, `discovery/vram-temp/vramtemp-pan-rijovich.sh`, governor stopped): unlock and payload succeeded ("SMU alive: True"), 15/15 read cycles returned all 8 chips, no `smu_error.log`, no kernel messages, governor restarted. Idle average 31-34 °C, chips 28-38 °C; the hotspot moves between chips (one code step is 2 °C). Nothing reads it continuously yet; a second read in the same power cycle needs `SKIP_PATCH=1`. GDDR6 has no I2C; per-chip temperature (8 chips, JEDEC MR3) is read through the SMU/UMC, which needs SMU code that stock firmware lacks. SMU firmware here is 88.6.0 (`0x00580600`), VBIOS `113-AMDRBN-003`, DMI `bios_version` `P3.00`. Code review 2026-10-28:
  - All three routes load one payload into volatile SMU RAM at `0x3AA9C` and serve it as Queue 3 messages 5-7 (UMC regs `0x53a1c`-`0x53a2c`, temp = code × 2 − 40). Hexxeh's embedded blob is pan-Rijovich's first `SMUPayload.bin`. Undo is a power cycle; `rmmod` does not unpatch.
  - `pan-Rijovich/bc250-memory-temperature` (MIT, rev `4a2221d`): `patch_smu.py:25` refuses unless the SMU reads `0x00580600`, matching this board. It opens the SMU debug gate with a memory-corruption exploit of Queue 2 message `0x23` (`unlock.py`). No locking of its own.
  - `Hexxeh/bc250-memory-dkms` (GPL-2.0-or-later, payload MIT): checks only DMI board name, not the SMU version, and has no unlock: on a locked gate it logs "BIOS unlock required" and registers nothing (`bc250_smu_patch.c:162-169`). So it needs an SMU-unlocked BIOS or a prior pan-Rijovich unlock. It drives `0xB8`/`0xBC` with `pci_*_config_dword` from the kernel, outside the `/sys/.../config` flock the governor and Control Center take, so it cannot be coordinated.
  - Control Center (MIT) runs pan-Rijovich's code pinned by SHA-256, holds the flock across a whole sample, saves and restores the `0xB8` index, and refuses within 5 s of a governor start. It is the only single-reader route.
  - Risks per upstream and Control Center: the read uses the GDDR6 DQ bus and can corrupt memory or crash; a sample during the governor's Queue 3 startup messages (~5 s) or a second sampler on the same mailbox has hung boards.
- **8-core GPU metrics are wrong on this kernel** (2026-10-28, 16 threads, 7.3 + 40 CU KMP): `current_gfxclk`, `pp_dpm_sclk`, hwmon `sclk` and `amdgpu_pm_info` SCLK read 2-100 MHz with the governor floor at 500 (offset 0x44 is `C0Residency[6]` in the 8-core layout). `temperature_core[0..3]` hold cores 6-7 power; only `[4..5]` are temperatures; slots 6-7 are always `0xFFFF`. higorprado's `bc250-core-cu-unlock/kernel/patches/0001-bc250-8core-telemetry.patch` reads gfxclk with an SMU message and picks the 8-core layout; it applies with `--fuzz=0` on top of our 40 CU patch and `cyan_skillfish_ppt.o` compiles with W=1. It has no license header. The `average_*` fields still look wrong (`average_gfxclk` ~225 MHz) and the patch does not touch them.
- **amdgpu sysfs reads message the SMU** (source review, 7.3.0-1.1; effect on the board not observed): every amdgpu hwmon value, `pp_dpm_*` and a live `gpu_metrics` read send `TransferTableSmu2Dram` on the MP1 mailbox at SMN `0x03B10A08` (`smu_cmn.c`, `cyan_skillfish_ppt.c`). The governor sends `force_gfx_freq`/`vid` on that same mailbox (its "queue 0") outside amdgpu's lock. The governor's bind-mounted `gpu_metrics` copy costs no SMU message. `gpu_busy_percent` returns EOPNOTSUPP.
- **Only power reading is amdgpu PPT** (`power1_average`), which is the whole APU, CPU plus GPU. About 43-45 W idle, 64 W with a desktop open.
- **High idle draw (shortcoming):** 43-45 W PPT at idle. Under light load (5-9% busy, a game running, 706 samples) the split is PPT 45 W = CPU rail 4 W + GFX 15 W (governor floor 1000 MHz / 800 mV) + 26 W rest (SoC, memory, display; not split further). `pp_dpm_mclk` and fclk have a single level, so memory never clocks down. A true-idle split is not done yet.
- **Wall draw (Kill-A-Watt, user, 2026-10-25, 40 CU / 8 cores / 1500 MHz cap, stock cooler with user fan curves):** idle ~82 W. FurMark + s-tui stress: peak 250 W, settling to ~210 W as it throttles. FurMark alone: ~220 W. Idle wall minus idle PPT is ~37 W (PSU loss, fans, board, outside PPT); not split further. PSU: the user's 500 W Flex ATX.
- **Quiet idle baseline (user, 2026-10-28, `discovery/memory-profile/baseline_sample.py`, governor min 500, ASPM `powersupersave`, no builds or FurMark):** PPT ~31.5-32 W, GFX rail ~5.6-6.1 W, CPU rail ~0.4-1.5 W, load1 ~0.1; mclk/fclk/uclk 450 MHz, socclk 1254 MHz.
- **GPU idle floor (user, wall meter, 2026-10-25):** governor min 1000 → 500 MHz cuts idle wall draw ~82 → ~67 W with no stutter; 100 MHz is no better than 500. Software at idle with min 500: PPT ~32 W (was ~41 W), GFX rail ~6 W (was ~15 W), CPU rail ~1 W. 60 Hz instead of 144 Hz saves ~2 W; the user keeps 144 Hz and VRR.
- **PCIe ASPM.** Boot policy is `default` (`CONFIG_PCIEASPM_DEFAULT=y`, no cmdline parameter), which keeps the BIOS's off state (`LnkCtl: ASPM Disabled` everywhere, 2026-10-27). The user set `powersupersave` at runtime on 2026-10-28; not persistent. Under it, `lspci` `LnkCtl` matches sysfs `link/` (2026-10-28, `discovery/aspm/aspm-probe.sh evidence`): GPU `00:08.1` → `01:00.x` L0s+L1 at 16 GT/s x16, no L1SS; NVMe `00:15.0` → `03:00.0` L1 on both ends; NIC L0s only. FADT `IAPC_BOOT_ARCH` is `0x0003` (no-ASPM bit clear) and `_OSC` grants PCIeCapability (platform has no LTR, SHPCHotplug or DPC), so firmware does not block it. NIC L1 is off because `r8169` calls `pci_disable_link_state(L1)` for RTL8168h without the vendor ASPM-safe flag (`r8169_main.c`). A/B on the NIC (`toggle 0000:04:00.0`): `link/l1_aspm=1` gave `LnkCtl: ASPM L0s L1 Enabled`, PPT 31.76 → 31.54 W (noise), ping 10/10, no AER or kernel errors; restored to 0. The NVMe (Gen4 x4 part) trains at 5 GT/s x2 (`LnkSta` downgraded); its `LnkCap` exit latency and `DevCap` acceptable latency are both "L1 unlimited", so the kernel keeps L1. It has L1.1/L1.2 (`L1SubCap`), but root port `00:15.0` has no L1 PM Substates capability, so they cannot be enabled. NVMe and NIC power is outside PPT; any saving needs the wall meter.
- mclk (450 MHz) and fclk have one DPM level in sysfs, and `amdgpu_pm_info` reports MCLK 450 MHz. Whether that is the live memory clock or a static table value is not known. Memory, memory controller and fabric clocks are changed together by SMU Queue 3 message `0x1E` (performance profile 1/2/3, about 450/850/1750 MHz per the governor's `memory-profile` branch), sent at runtime: no flash. The default is profile 3. Community wall idle: 60 → 30 W with a static profile 0 (dan2wik), 46-49 W with the branch cycling profiles (two users). Reported failures: about 1 in 20 profile writes fabric-faults and locks the APU (dan2wik), and the branch "will eventually crash as P-state cycling is unstable" (iridium.io). On this board (2026-10-28, `discovery/memory-profile/`): step 1 test message 123 → 124 OK; one write of profile 2 returned OK, no lockup. `pp_dpm_mclk`, `pp_dpm_fclk` and `current_uclk` still read 450 MHz, so they do not show the profile. Idle PPT 32.4 → 32.0 W (noise; GDDR6 is likely outside PPT, wall meter needed). GPU global bandwidth (clpeak, Vulkan) 190 GB/s vs 448 GB/s theoretical at 1750 MHz; ~850 MHz gives ~218 GB/s theoretical, so profile 2 looks active, but there is no profile-3 measurement yet. 3 min sustained GPU memory load (94 runs, PPT ~78 W): no amdgpu errors. CPU single-thread memcpy 18.5 GiB/s. From the governor source (`memory-profile` branch, 2026-10-28): `0x1E` is set-only, there is no message that reads the active profile; `pp_dpm_mclk`, `pp_dpm_fclk` and `gpu_metrics` `current_uclk` all come from SMU `MemclkFrequency` and read 450 MHz, so either the board is not in profile 3 or that field is not the GDDR6 clock. v0.4.14 never sends `0x1E`. The branch is not packaged: it cycles profiles with no rate limit, writes 3 on every governor stop, and its default config changes `set-method`, `fix-metrics` and the clock ceiling.
- **GPU clock gating is off by driver design** (7.3.0-1 source, 2026-10-28): `nv.c:828-832` sets `cg_flags = 0` and `pg_flags = 0` for GC 10.1.3/10.1.4 since `b515937b414a` (2021), and `gfx_v10_0_set_clockgating_state`/`set_powergating_state` skip 10.1.3. AMD's `bca52455a3c0`: "cyan skillfish doesn't support any CG features". The "On" rows in `amdgpu_pm_info` are hardware-default read-backs; the all-ones SMC feature mask is hard-coded. `amdgpu.cg_mask`/`pg_mask` can only clear flags. GFXOFF is a no-op (no `.gfx_off_control`). RLC firmware `cyan_skillfish2_rlc.bin` is v2.0, ucode `0xd`, no save/restore list.
- **`nct6686` channels are unlabeled:** VIN0/1/2/6/7/16, fan1-5, pwm1-5, AMD TSI temp, Thermistors 14/15. No public mapping exists. A logging wall meter could calibrate PPT against real draw over time.
- `k10temp` gives Tctl only.
- **Software fan control works with `nct6687`** (2026-10-28, local build of `bc250-nct6687`): fan2 is the cooling fan. BIOS curve at idle: `pwm2_enable` 2, PWM 178, ~1500 rpm. Manual PWM 255 → 1960 rpm, 77 → 952 rpm. Writing `pwm2_enable=2` or unloading the module returns it to PWM 178. The fan is an Arctic P12 (not Max), so ~1960 rpm is its ceiling. The log line `force=1 refused: chip ID 0xffff` is the empty second Super I/O probe at `0x4e`; the chip is at `0x2e`.

## Host state (checked 2026-10-25, updated 2026-10-28)

- Bootloader is **systemd-boot** (`LOADER_TYPE="systemd-boot"`, `sdbootutil` present, no `grub2-mkconfig`). GRUB-based ACPI delivery does not apply.
- Kernel `7.3.0-1-default`, root on LVM + btrfs snapshots, SELinux enabled on cmdline. `amdgpu` loaded; no `nct668x` module and no modprobe/modules-load config.
- CPU family 23 model 71 (0x47); root complex `1022:13e0`.
- 8 cores / 16 threads after the `bc250-8core-unlock` warm reboot (2026-10-25 19:48). Also worked on P2.00.
- GPU is `card1` (`1002:13fe`, `amdgpu`).
- BIOS `P3.00` Chipset Menu (2021-12-09), flashed 2026-10-25 from `P2.00`. UMA Frame Buffer 512M, IOMMU disabled. `mem_info_vram_total` 512 MiB, 14 GiB RAM visible (was 8192 MiB / 7.5 GiB).
- SVM is enabled in BIOS setup (`svm` flag and `/dev/kvm` present, 2026-10-28; the 2026-10-27 CMOS clear had turned it off). IOMMU off (`/sys/class/iommu` empty). Local `osc build` uses chroot via `sudo /usr/bin/build` (NOPASSWD in `/etc/sudoers.d/osc-build`).
- `fwupdmgr get-devices` lists no system firmware device (only CPU, GPU, NVMe). The board has no UEFI capsule update path, so `fwupdmgr` cannot flash its BIOS.
- `CONFIG_ACPI_TABLE_UPGRADE=y`, `CONFIG_DEBUG_FS=y` and mounted, `MODULE_SIG_FORCE` not set. Secure Boot disabled (firmware reports unsupported). Lockdown `none`.
- Stock firmware exposes no `cpuidle` or `cpufreq`. With `bc250-acpi-tables` installed, all 16 CPUs have `acpi_idle` (POLL/C1/C2) and `acpi-cpufreq` (2026-10-25).
- Before `bc250-setup`: hwmon showed `nvme`, `amdgpu`, `k10temp` only. See Sensors for the current state.
- Not installed: `sensors`, `coolercontrol`. `osc` is installed and authenticated (keyring).
- Added 2026-10-28 for the memory-profile test: `clpeak`, `Mesa-libRusticlOpenCL`, `libOpenCL1`, `libclc` (zypper), and a root-owned copy of `memprofile-step2-static.sh` at `/usr/local/sbin/bc250-memprofile-step2` (systemd cannot exec from `/home`). Logs: `/var/log/bc250-vramtemp/`, `/var/log/bc250-memprofile-soak.log`. pan-Rijovich's checkout: `~/Code/bc-250-community-repos/bc250-memory-temperature` at `4a2221d`.
- `/etc/sudoers.d/claude-bc250-temp` grants the agent sudo for testing; remove it when done.
- In OSS: `osc 1.28.0`, `obs-service-cargo 7.2.2`, `cargo-packaging 1.5.0`, `coolercontrol 4.3.1`. `umr` only in the `hardware` devel project. Not in OSS: `nct6687`.

## Upstream licenses and AI policy

No project below publishes a contributing guide or AI policy. openSUSE has no AI-contribution policy that could be found. Ask maintainers before sending AI-assisted PRs.

| Project | License |
| --- | --- |
| filippor/cyan-skillfish-governor | MIT |
| Fred78290/nct6687d | GPL-2.0 |
| GabriWar/bc250-core-cu-unlock | MIT |
| e-tho/bc250-acpi-fix | MIT |
| fanoush/bc250_memcfg | MIT |
| tomstdenis/umr | MIT (`LICENSE`, AMD 2017) |
| WinnieLV/bc250-cu-live-manager | **none**: not redistributable, cannot ship in OBS as-is |
| duggasco/bc250-40cu-unlock | GPL-2.0 (README; no `LICENSE` file). The patch carries `Signed-off-by` against GPL-2.0 kernel code. |
| mendesrr/bc250-acpi-fix-updated-8c | **none** (fork of bc250-collective/bc250-acpi-fix, also unlicensed): not redistributable |
| this repo | MIT (`LICENSE`, confirmed by the user 2026-10-25), except `src/bc250-amdgpu/bc250-40cu-amdgpu.patch` (GPL-2.0) |

Contribution candidates for filippor/cyan-skillfish-governor:

- **D-Bus policy:** `<allow send_interface=…>` rules with no `send_destination` in the default context let any user send those interfaces to every system bus service. Our patch scopes every rule to `com.cyanskillfish.Governor` and keeps TestMode root-only.
- The unit is `WantedBy=default.target`; a system service normally uses `multi-user.target`.
- `Cargo.toml` says `0.4.0` at tag v0.4.14; the binary only reports the tag because `build.rs` reads `CYAN_SKILLFISH_GOVERNOR_VERSION` or `git describe`.

## BIOS and VRAM

- **No flash needed.** The elektricm flashing guide: flashing is "only needed if you want the unlocked chipset menus or features beyond VRAM sizing".
- **VRAM split without flashing:** `fanoush/bc250_memcfg` writes `UMA_SIZE` to battery-backed extended CMOS (I/O ports `0x72`/`0x73`, block `0x90-0xAB`, own checksum), not to flash. Recommended split 512 MB; all splits are dynamic. 2 GB does not boot. Revert by clearing CMOS. A CMOS clear also erases it, so re-apply after.
- It builds with `make`, so it would need an OBS package. Not needed on this board: the P3.00 Chipset Menu sets the split in BIOS setup.
- No version adds anything needed here. P3.00 Chipset Menu is the community standard. P5.00_clv adds experimental ReBAR and is easy to brick. MeiMeiDXE adds an 8-core unlock at boot and also rewrites the boot block.
- **This board's flash (P2.00 → `BC250_3.00_CHIPSETMENU.ROM`, SHA256 `48fbe5d3…40b5`):** the diff is wider than the guide's tested P3.00 pair. It also changes the PSP directory (`$PSP` at `0x8e0000`), PSP firmware (`0x990000-0x9cffff`) and AMD tables in the PEI volume (`0xeb0000-0xefffff`). The last 512 KB is identical. `bios_flashing/flash.layout` lists the six differing ranges. NVRAM was written first, then the other five in one run. Readback hash matched; CMOS cleared after.
- Linux flashing is `flashrom -p internal`, which rewrites the chip the board booted from, with no firmware-side check. A hardware programmer (CH347 or Pi Pico serprog; not a black CH341A) is the only guaranteed recovery. The target chip is `BIOS_A1`, never `SIO1_R`.

## Safety warnings

From the sources below; none verified on this board yet.

- **SMU contention.** `cyan-skillfish-governor-smu` drives the same PCI index/data pair (`0xB8`/`0xBC` on `00:00.0`) as the 8-core unlock. Stop the governor before any SMU access, reads included. Restart after. `bc250-8core-unlock.service` is ordered `Before=` the governor for this reason.
- **`bc250_detect.py` is not read-only.** It applies an SMU state and writes `overclock.conf` as a side effect. Never use it as a status check.
- **Unknown core masks.** Stock mask at SMN `0x0115A870` is usually `0x77`, but boards reading `0xD7` exist. Refuse to act on any mask that isn't the expected value. Both packaged scripts refuse; the 8-core unit then fails (exit 1).
- **Unlocks are volatile.** Cold boot reverts both the 8-core and 40 CU unlocks; warm reboot keeps them. Nothing is flashed, so pulling power is the rollback.
- **One sensor driver.** In-kernel `nct6683` and out-of-tree `nct6687` conflict. Load one, blacklist the other.
- **40 CU patch upstream is archived.** `duggasco/bc250-40cu-unlock` will not track new kernels; we carry the rebase in `src/bc250-amdgpu/`. When a kernel moves the hunk context, the OBS build fails at `%prep` until rebased. The KMP's `ksym()` requires pin it to one kernel build; by weak-modules2's design a newer kernel without a rebuilt KMP boots its own in-tree `amdgpu` (24 CU). Not observed yet.
- **40 CU loads from the initrd.** `plymouth` is installed, so dracut's `drm` module puts `amdgpu` in the initrd (initrd is root-only, contents not checked). Install and removal rebuild the initrd (`-b`). Rollback without removing: `/etc/modprobe.d/50-bc250-40cu.conf` with `options amdgpu bc250_cc_write_mode=0` (same name overrides the vendor file), `sudo dracut -f --regenerate-all`, reboot. One-off: add `amdgpu.bc250_cc_write_mode=0` to the cmdline in the systemd-boot editor. Or `zypper rm bc250-amdgpu-kmp-default`.
- **ACPI tables load from the initrd.** If a table breaks boot, pick an older entry or snapshot in systemd-boot, then remove `bc250-acpi-tables`.

## Open questions

- VRAM temperature: make it continuous? Needs one reader at a time on the Queue 3 mailbox, kept clear of the governor's startup messages (Control Center's rule: none within 5 s of a governor start). Package a reader service, or use Control Center? Does the reading hold under GPU load?
- Memory/fabric profile: profile 2 is set this boot; an 8 h soak (transient unit `bc250-memprofile-soak`, `/var/log/bc250-memprofile-soak.log`) started 2026-10-28 10:02. Open: wall-meter reading at profile 2 vs ~67 W; clpeak bandwidth after the next cold boot (profile 3) to confirm the drop to 190 GB/s; whether a warm reboot keeps profile 2; then whether to package a one-shot boot unit.
- ASPM: persist a policy? NIC L1 showed no PPT change and no errors; NVMe L1 is already on under `powersupersave`, L1SS is impossible on `00:15.0`. Only the wall meter can show a gain. With no L1SS on any link here, `powersave` (L0s+L1) and `powersupersave` (adds L1SS) should behave the same.
- GPU clock gating: does an opt-in GFX CGCG patch (`amdgpu.bc250_cg=1|2`, default 0, `discovery/clock-gating/`, built locally, never booted) cut idle PPT and stay stable? AMD says the chip has no CG support; expected gain is small. Low priority.
- 8-core telemetry patch: ship it in `bc250-amdgpu`? Needs a full KMP build (amdgpu builds need `--vm-memory=3072 --vm-disk-size=16384 --jobs=4`), a live check of `pp_dpm_sclk`/hwmon `sclk`, and the patch's license.
- Fan curves: switch `bc250-setup` from `nct6683` to `nct6687` and pick a curve tool (CoolerControl is in OSS)?
- Telemetry logger: publish `bc250-telemetry-log` (CSV every 10 s to `/var/log/bc250`, reads only the governor's `gpu_metrics` copy, `src/bc250-telemetry-log/`, built locally, 32 tests pass)? Unchecked: whether the governor's bind mount reaches its sandbox.

## Sources

- https://elektricm.github.io/amd-bc250-docs/system/governor/
- https://elektricm.github.io/amd-bc250-docs/system/40cu-unlock/
- https://elektricm.github.io/amd-bc250-docs/system/8core-unlock/
- https://elektricm.github.io/amd-bc250-docs/system/sensors/
- https://elektricm.github.io/amd-bc250-docs/system/power/
- https://elektricm.github.io/amd-bc250-docs/troubleshooting/stability/
- https://elektricm.github.io/amd-bc250-docs/bios/flashing/
- https://elektricm.github.io/amd-bc250-docs/bios/vram/
- https://www.skillfishos.com/en/docs/hardware-bc250/
- https://github.com/lorek123/bc250-notes (DSDT dump)
- https://github.com/fanoush/bc250_memcfg
- https://github.com/mothenjoyer69/bc250-documentation/blob/main/hardware.md
- https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/pm/swsmu/inc/pmfw_if/smu11_driver_if_cyan_skillfish.h
- https://github.com/filippor/cyan-skillfish-governor (branch `smu`)
- https://github.com/duggasco/bc250-40cu-unlock (archived; `docs/technical-report.md`)
- https://github.com/WinnieLV/bc250-cu-live-manager
- https://github.com/GabriWar/bc250-core-cu-unlock
- https://github.com/GabriWar/bc250-core-cu-unlock/issues/1 (mask `0x7D` on P3.00 Chipset Menu) and pull/2
- https://github.com/mendesrr/bc250-acpi-fix-updated-8c
- https://github.com/e-tho/bc250-acpi-fix
- https://github.com/Fred78290/nct6687d
- https://gitlab.freedesktop.org/tomstdenis/umr
- https://build.opensuse.org/package/show/hardware/umr
- https://github.com/torvalds/linux/blob/master/drivers/platform/x86/amd/pmc/pmc.c
- https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/amdgpu/amdgpu_acpi.c
- https://build.opensuse.org/project/show/home:superppl:bc250
- https://github.com/pan-Rijovich/bc250-memory-temperature
- https://github.com/Hexxeh/bc250-memory-dkms
- https://github.com/Hexxeh/bc250-vrm-dkms
- https://github.com/onlinermm/BC250-Telemetry (`hardware.md`: VRM I2C mod)
- https://github.com/filippor/cyan-skillfish-governor (branch `memory-profile`)
- https://github.com/GabriWar/bc250-core-cu-unlock (`kernel/patches/0001-bc250-8core-telemetry.patch`)
- https://github.com/movacx/bc250-control-center (`privileged/helpers/bc250-gddr6-temp-*`)
- bc250-unofficial-community-guide: `06-gpu-governor.md` (SMU performance profile tuning), `02-bios-and-firmware.md` (GDDR6 MR3), `03-power-supply-guide.md` (VRM telemetry)
