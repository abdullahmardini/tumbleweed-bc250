# BC-250 handoff

Status (2026-10-28): packages from `home:superppl:bc250` installed via the `bc250` repo. 40 CU, governor 500-1850 MHz. BIOS P3.00 Chipset Menu, 512 MB VRAM split, SVM on. Power-cycled 17:03 after the SMU hang: SMU answers, governor active, 12 CPUs until a warm reboot.
Goal: run the BC-250 as a desktop replacement on openSUSE Tumbleweed, packages built in OBS, contributing upstream. Next goals: working s2idle (sleep and wake) and Secure Boot.

## Decision

Option 3: a small OBS project plus one `bc250-setup` meta RPM. Host setup is `zypper ar` + `zypper in bc250-setup`; `zypper dup` keeps it current.

- One package per piece: governor, `umr` (debug tool, nothing requires it), the 40 CU `amdgpu` KMP, ACPI tables, the 8-core script.
- `bc250-setup` ships the sensor config, the suspend block and a systemd preset (governor, 8-core unit). Its only scriptlet is one `systemctl preset` on first install. It does not pull in the KMP. 0.2.0 has `Obsoletes: bc250-40cu <= 0.1.0` / `Provides: bc250-40cu = 0.2.0`.
- Installing the KMP enables 40 CU (`options amdgpu bc250_cc_write_mode=3` in `/usr/lib/modprobe.d/50-bc250-40cu.conf`).
- Governor default `min = 500`, `max = 1850` (upstream 1000-1850) in its `%config(noreplace)`; `%prep` fails if upstream changes those lines. Ceiling 1850 is the user's decision (2026-10-26).
- Memory/fabric profile 2 is opt-in, not the default (user, 2026-10-28). Profile 1 is not offered.
- Per-board values (voltage curve, CU layout) stay in this repo.

Build order; finish one before starting the next:

1. Governor RPM. Done.
2. `umr` and the 40 CU KMP. Done.
3. Sensor config, ACPI tables, `bc250-setup`. Done.
4. Package the 8-core script. Done (r3 pending, see packages).
5. Upstream contributions, one project at a time (see Participation plan).

## Rejected

| Option | Why rejected |
| --- | --- |
| Governor RPM only, rest by hand | Only the governor updates; the rest drifts. |
| OBS packages, configs copied by hand | Setup stays a manual checklist. |
| Upstream-first (Factory, devel projects) | Slow review before anything runs. Deferred to step 5. |
| No RPMs, upstream tarballs and scripts | Nothing updates on its own. |
| 40 CU via DKMS or a patched `kernel-default` | DKMS compiles on the host; a patched kernel means maintaining a kernel. The KMP rebuilds only `amdgpu` from `kernel-source` in OBS. |
| Runtime 40 CU through `umr` (`bc250-40cu`, retired 2026-10-26) | `gfx_v10_0_get_cu_info()` reads `CC_GC_SHADER_ARRAY_CONFIG` only in hw_init and caches it for RADV and KFD (7.3.0-1.1: gfx_v10_0.c:5350/10090, amdgpu_kms.c:1010, kfd_crat.c:2304). Later writes leave 24 CUs reported. SPI `0x1F` alone gave no gain (duggasco). |
| Shipping WinnieLV's live manager | No license. |
| Masking sleep targets from a package | `/etc` is admin territory. A `sleep.conf.d` drop-in in `/usr/lib` does the same and can be overridden. |
| Memory profile 1 | Hung the board under GPU load (2026-10-28). |
| Governor `memory-profile` branch | Cycles profiles with no rate limit (community: ~1 in 20 writes fabric-faults), writes 3 on every stop, changes `set-method`, `fix-metrics` and the ceiling. |
| SMU deep-sleep features (DS_SOCCLK, DS_SMNCLK, DS_FUSE_SRAM, DS_GFXCLK) | Enabled, no wall change. |
| SMU feature MGCG | Enable hangs the SMU until a power cycle. |
| SMT off + CPU max 800 MHz | Idle wall 46-48 W vs ~47 W; Superposition halved. |

## The pieces

| Piece | What it is | Package |
| --- | --- | --- |
| Governor | GPU clocks and voltage; its curve is the undervolt | `cyan-skillfish-governor-smu` |
| 40 CU | CC/SPI/RLC writes in `amdgpu` init, behind `amdgpu.bc250_cc_write_mode=3` | `bc250-amdgpu-kmp-default` |
| 8-core | SMU message `0x98` sets the core mask | `bc250-8core-unlock` |
| Sensors | `options nct6683 force=1`; `nct6687` only for software fan curves | Config in `bc250-setup`; `bc250-nct6687-kmp-default` (not loaded by anything) |
| CPU power states | `acpi_idle` C1/C2 and `acpi-cpufreq` from ACPI tables | `bc250-acpi-tables` |
| Suspend | Disabled until s2idle works | Config in `bc250-setup` |

## OBS packages (`home:superppl:bc250`)

| Package | Source | Notes |
| --- | --- | --- |
| `cyan-skillfish-governor-smu` | tag v0.4.14 (`7b08fdc`), crates vendored | 37 tests in `%check`. Carries `dbus-policy-scope-to-destination.patch`. rpmlint `dbus-file-unauthorized` matters only for Factory. |
| `umr` | `osc linkpac hardware umr` (1.0.11, MIT) | Has `cyan_skillfish.asic` and the 40 CU registers. Kept to read CC/SPI per SE/SH. |
| `bc250-8core-unlock` | GabriWar `c532536`, script and LICENSE only, plus `bc250-8core-unlock-fail-on-refusal.patch` | Patch: `boot` exits 1 on every refusal or failure; refuses a 00:00.0 that is not `1022:13e0`. Unit is `Before=` the governor, no `Requires=`. r3 (built locally, not committed): `bc250-8core-check` as `ExecStartPost=-`; 16 CPUs quiet, 12 CPUs journal warning + `/run/motd.d` notice + exit 2 without failing the unit. Not yet seen at a real cold boot. |
| `bc250-acpi-tables` | e-tho/bc250-acpi-fix v1.1.1, `iasl` | dracut drop-in sets `acpi_override`/`acpi_table_dir`; `%regenerate_initrd_post`. Covers P000-P00F, so stock and unlocked boards. `%check` fails if any processor object lacks its methods. mendesrr's fork not used: no license, publishes C3 (e-tho reverted C3 for freezes), one `_PSD` domain. |
| `bc250-setup` | `src/bc250-setup/` | 0.2.0. |
| `bc250-amdgpu-kmp-default` | duggasco `ae7c30c`, rebased onto 7.3 in `src/bc250-amdgpu/` | Builds only `amdgpu.ko` against `linux-obj`, installs to `updates/`. `patch --fuzz=0`; `%build` checks the parameter and vermagic. `ksym()` requires match `kernel-default` 7.3.0-1.1. `-b` rebuilds the initrd. Unsigned (taints, loads). |
| `bc250-nct6687-kmp-default` | Fred78290/nct6687d `ec1030b` (GPL-2.0) | Ships `options nct6687 force=1`; no alias, nothing loads it; cannot bind while `nct6683` holds the chip. |

Local amdgpu builds need `--vm-memory=3072 --vm-disk-size=16384 --jobs=4`.

## 8-core

- Factory mask on this board 0x77; accepts 0xFF (not the `0x7D` case of GabriWar issue #1). PR #2 (accept any one-off-per-cluster mask) not adopted: no hardware evidence.
- The unit sets the mask every boot; cores appear after the *next warm* reboot. After a cold boot it logs `mask set to 0xFF -- all 8 cores will appear on your next reboot`, exits 0 with 12 CPUs. `nproc` is the check.
- `/sys/kernel/reboot/mode` is `cold`, type `acpi`.
- ACPI tables cover all 16 threads: cpuN has apicid N and `\_PR_.P00N`; siblings (2k, 2k+1) match `_CSD`/`_PSD`. 8 P-states 800 MHz-3.2 GHz.

## 40 CU

Registers per shader array (SE0-1 × SH0-1), duggasco's report:

| Register | Stock | Unlocked | Role |
| --- | --- | --- | --- |
| `CC_GC_SHADER_ARRAY_CONFIG` | `0xfff80000` | `0xffe00000` | How many CUs the driver reports |
| `SPI_PG_ENABLE_STATIC_WGP_MASK` | `0x7` | `0x1f` | Which WGPs receive waves |
| `RLC_PG_ALWAYS_ON_WGP_MASK` (global) | | `0x1f` | Set alongside SPI |

The patch writes all three just before `gfx_v10_0_get_cu_info()` in hw_init, so they are redone on resume and GPU reset. MMIO, not the SMU mailbox.

Superposition 1080p Extreme on this board (user):

| Config | Runs | Average |
| --- | --- | --- |
| 24 CU, 6 cores, governor | 3164, 3190, 3191 | 3182 |
| 24 CU, 8 cores, fan curves changed | 3775, 3787, 3733 | 3765 |
| 40 CU, 8 cores, max 1500 MHz | 4124, 4128, 4125 | 4126 |
| 40 CU, 8 cores, 500-1850 MHz, after heat soak | 4887, 4893, 4888 | 4889 |
| Same, memory profile 2 | 3989 | (1 run, -18%) |
| Same, profile 1 + SMT off + 800 MHz | 2579 | (1 run) |

No clocks or temperatures were logged in any run; whether 1850 MHz throttles is unknown.

## Power

Wall meter (user, 2026-10-28; 40 CU, 8 cores, governor 500-1850, 144 Hz VRR, desktop idle):

| Step | Wall | PPT |
| --- | --- | --- |
| Baseline | ~69 W | 33.7 W |
| ASPM `powersupersave` + NIC L1 | ~67 W | |
| Memory profile 3 → 2 | **~52 W** | 31.9 W |
| Profile 2 → 1 | ~47 W | 31.3 W |
| Four SMU DS_* features | no change | ~31.8 W |

- Most of the profile saving is outside PPT (GDDR6, fabric).
- Profile 2 under load: FurMark peak ~200 W vs ~250 W, no thermal throttling.
- Profile 1 hung the board under Superposition (blank screen, no amdgpu error or MCE).
- Earlier (2026-10-25): governor min 1000 → 500 MHz cut idle ~82 → ~67 W, no stutter; 100 MHz no better. 60 Hz vs 144 Hz ~2 W (VRR state during that test not recorded).
- **Memory profile:** Queue 3 `0x1E`, profiles 1/2/3 ≈ 450/850/1750 MHz memory, memory controller and fabric. Set-only, no read-back. Cold boot restores 3. `pp_dpm_mclk`/`fclk`/`current_uclk` read 450 at profiles 3 and 2, 850 at 1: not the GDDR6 clock. clpeak at profile 2: 190 GB/s (448 theoretical at 1750). Tool: `discovery/memory-profile/memprofile-step2-static.sh set|soak|restore` (root copy `/usr/local/sbin/bc250-memprofile-step2`). BIOS source: ABL1 has the u16 table `1750,1330,1330,850,225,0,0,225` at `0x16a00` (P2=P3); APCB MEMG types 0x7/0x8 hold 1750, 450/850 absent from the APCB. 1750 is likely profile 3's GDDR6 clock (×8 = 14 Gbps); the 225 pair may underlie profile 1's ~450 (guess).
- **No RAPL** (0 fixed counters, `/sys/class/powercap` empty). CPU rail power is `gpu_metrics` `average_soc_power` (0x2C, VDDCR_VDD); `average_gfx_power` (0x2E) is VDDCR_GFX. PPT (`power1_average`) is the whole APU.
- **GPU clock gating is off by driver design:** `nv.c` sets `cg_flags = pg_flags = 0` for GC 10.1.3; AMD `bca52455a3c0`: "cyan skillfish doesn't support any CG features". GFXOFF is a no-op.
- **SMU features (firmware 88.6.0):** Q0 `0x3D` ignores its argument, returns bits 0-31: `0xDD602C7D`. Off: GFXCLK_EFFT_FREQ, DS_LCLK, RM, DS_MP1CLK, DS_MP0CLK, MGCG, GFX_CKS, FP_THROTTLING, UMC_THROTTLE, DS_MP3CLK, DFLL_BTC_CALIBRATION (plus the four DS_* enabled at runtime above). v11.8 has no UCLK DPM and no DS_UCLK/DS_FCLK: nothing downclocks memory within a profile. Q2 `0x05` with the bit as argument enables a feature until power-off. Tool: `discovery/smu-features/smu-features.sh status | enable NAME q2|q3`. amdgpu never sends `0x3D` (fills ones).
- **PCIe ASPM:** boot policy `default` keeps the BIOS's off state. `powersupersave` at runtime (not persistent): GPU L0s+L1, NVMe L1, NIC L0s. FADT and `_OSC` don't block ASPM. `r8169` disables NIC L1 for RTL8168h; `link/l1_aspm=1` works (no errors). NVMe trains at 5 GT/s x2; root port `00:15.0` has no L1SS capability, so `powersave` and `powersupersave` behave the same. Tool: `discovery/aspm/aspm-probe.sh`.
- **VRR:** GNOME `refresh-rate-mode` `variable`, DP-1 `vrr_range` 48-144; idle desktop drops to the 48 Hz floor between flips (`amdgpu_refresh_rate_track`).

## SMU mailbox

Source read (kernel 7.3.0-1 tree, governor and community repos), not probed. `C2PMSG_n = 0x3B10900 + 4n`.

| Queue | cmd | resp | arg |
| --- | --- | --- | --- |
| Q0 (driver) | `0x3B10A08` | `0x3B10A68` | `0x3B10A48` |
| Q1 | `0x3B10A00` | `0x3B10A60` | `0x3B10A40` |
| Q2 | `0x3B10528` | `0x3B10564` | `0x3B10998` |
| Q3 (control) | `0x3B10A20` | `0x3B10A80` | `0x3B10A88` |
| Q4 | `0x3B10A24` | `0x3B10A84` | `0x3B10A8C` |

- Q3 arg2 == Q4 arg1 (`0x3B10A8C`). Userspace: `0xB8` addr / `0xBC` data on `00:00.0`; amdgpu drives Q0 by MMIO under its own lock. The governor flock is per 32-bit access, not per addr/data pair — userspace SMU tools can race each other and corrupt a message.
- Resp codes: `01` OK, `00` busy/timeout, `FF` fail, `FE` unknown cmd, `FD` prereq, `FC` busy, `FB` debug end. An unknown resp sets `SMU_FW_HANG`; the driver then sends nothing.
- **Q0** (IDs `0x01-0x3D`; kernel sends `01-07,0E,3B,3C`): getters `01` Test(n+1), `02` GetSmuVersion=`0x00580600`, `0C` core pstate, `37` GetGfxFreq MHz, `38` GetGfxVid, `3D` GetEnabledSmuFeatures (arg ignored). Setters `0E` RequestGfxclk, `39/3A` Force/Unforce GfxFreq, `3B/3C` Force/Unforce GfxVid (VID=(1550-mV)/6.25, clamp 700-1129 mV), `2C` SetCoreEnableMask, `35/36` soft min/max CPU clk, `2E` InitiateGcRsmuSoftReset (GPU reset, dangerous). Tables `04/05` DRAM addr, `06` copy metrics.
- **Q3** (`0xA9`-entry handler table in SMU SRAM at `0x7464` → IDs `0x00-0xA8`): `1E` memory profile, `98` core mask, `0F/10` force/unforce VID, `25/26` OC clock, `36/37` CPU/GPU voltage, `50` VID curve scale, `8B/8C` max CPU/GPU temp, `8F` max CPU boost, `9A` disable extra voltage, `3C/3D` feature enable/disable. `28-2C` arbitrary SMN read/write, gated (`2A` returns `FD` while closed). `47/48` inert (`FE`).
- **Q2**: `05/06` feature enable/disable (mask in arg; MGCG enable hung the SMU), `0A` transfer engine, `0D-10` table addrs, `23` ring-append exploit (VRAM-temp payload).
- **Undocumented** (no kernel name, no repo wrapper): Q0 `08,09,10,12,15,1F-2B,2D,32,33`; ~60 Q3 IDs across `0x02-0xA6`. Q1/Q2/Q4 max ID unknown.
- SMU firmware is **plaintext** in the BIOS at `0x8ff000` (`0x40200` B, v0.88.6.0, type `0x08`); type `0x12` at `0x93f700` is a signed stub. Disassembling the blob or dumping the Q3 handler table (needs the `0x28-0x2C` gate open) beats blind probing.

## BIOS / SMU reverse engineering

Moved to `bios_flashing/HANDOFF.md`; tooling is `bios_flashing/romtool.py` (uv project, `uv run romtool.py`). Headline: the AMD CBS power options (memory clock 450/850/1750, per-port ASPM L0s+L1, DF C-states, NBIO clock gating, SMU feature bits, fPPT/TDC) are all present in `CbsSetupDxe` and not exposed by the shipped menus; reachability needs an IFR walk before any menu patch.

## Suspend

- `mem_sleep` offers only `[s2idle]`. DSDT (same on BIOS 1.00-5.00, lorek123 dump) has `_S0`, `_S4`, `_S5`, no `_S3`, no LPS0 device (`PNP0D80`).
- BIOS dump (2026-10-28): UEFI carries the S3 path (S3Resume2Pei, BootScriptExecutor, PspS3Smm, SleepSmi) but no S0i3/LPS0 module and no PBS. No `_S3` or `PNP0D80` anywhere in either image, decompressed sections included. S3 is off by firmware policy (missing `_S3`), not missing resume code — an injected `_S3`/LPS0 via the initrd override is the lever, no flash. FADT built in code, flags `0x385A5`, `LOW_POWER_S0` clear.
- s2idle resumed once (P2.00; that boot then died a minute later) and hung once (P3.00). Wake source unknown (`pm_debug_messages` was 0).
- s2idle saves almost nothing: amdgpu logs `BIOS has not been configured for suspend-to-idle` (no FADT `LOW_POWER_S0`) and never suspends; no LPS0 device; `amd_pmc` does not match root complex `1022:13e0`; no AMD GPIO device, so `pinctrl_amd` is not loaded. `amd-s2idle` 0.2.22: "does not meet s2idle prerequisites" (report in `idle-report/`, not committed: holds monitor serials).
- Wake-capable: power button, RTC, USB/PCIe GPEs. USB root hubs have `power/wakeup` disabled.
- `pm_test` on s2idle cannot reach the idle loop. The real test is `rtcwake -m freeze -s 60` at the console with `pm_debug_messages=1`, ready to cut power. First attempt (2026-10-28 16:54) hard-hung the board, but the SMU was already hung from MGCG and nothing was logged (journal ends before `PM: suspend entry`, no pstore backend): invalid. Rerun with netconsole to a second machine (`CONFIG_NETCONSOLE=m`, dynamic).
- Debug ports: `ttyS0` (16550A at `0x3F8`, IRQ 4, SuperIO UART) exists but no header is documented; `CONFIG_EARLY_PRINTK_USB_XDBC=y` (needs a USB 3 A-A debug cable, DbC support unknown); `TPMS1` LPC for a POST-code card; `J2` HDT+ unpopulated.
- Hibernate: `_S4` present, `CONFIG_HIBERNATION=y`. Blocked: swap LV 2 GiB for 14 GiB RAM, and the resume boot is a cold boot, so 12 CPUs.
- P5clv has an "ACPI Sleep State" option; its DSDT has no `_S3`. Not tested.
- Community: elektricm says resume is unreliable; SkillFishOS disables all sleep.
- `bc250-setup` ships `AllowSuspend=no` / `AllowHibernation=no` (GNOME's AC idle default suspended the board both times).

## Secure Boot

- Firmware reports Secure Boot unsupported.
- **Stack stripped from the BIOS**, not merely disabled: no SecureBootDxe, no PK/KEK/db/dbx defaults, no authenticated-variable store, no TPM/fTPM — confirmed in both the P2.00/P3.00 dumps and live (2026-10-28). Enabling it needs a BIOS that ships the modules; the initrd/MOK path cannot add them. Signing the KMPs matters only once such a BIOS exists.
- Kernel has `CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT=y`. Under Secure Boot, integrity lockdown blocks:

| Piece | Blocked by |
| --- | --- |
| Governor, 8-core unit, memory profile, SMU tools | userspace PCI config writes (`0xB8`/`0xBC`) |
| `bc250-acpi-tables` | ACPI table override from the initrd |
| Both KMPs | unsigned modules |
| `umr` | debugfs writes |

## Participation plan

Ask each maintainer about AI-assisted PRs before sending; keep that rule (the user notes most of these projects already read as AI-written). One project at a time. Clones are HTTPS; the agent has no SSH agent (YubiKey touch) and no `gh` or GitHub MCP, so pushes and PRs are the user's.

| Goal | Work | Where |
| --- | --- | --- |
| s2idle | Run `rtcwake -m freeze` with `pm_debug_messages`; post results + `amd-s2idle` report | issue on e-tho/bc250-acpi-fix |
| s2idle | LPS0 device and FADT `LOW_POWER_S0` flag via the initrd override (no flash) | e-tho/bc250-acpi-fix |
| s2idle | SMU sleep-path handlers (S0i3 support unknown) | rw-r-r-0644 (read them while finding `0x98`) |
| s2idle | ACPI fixes in the BIOS | Forbidden-Darkness (MeiMeiDXE-T-v2) |
| Hibernate (fallback) | Bigger swap (us); 8 cores on cold boot needs MeiMeiDXE `Bc250CoreUnlockDxe` (rewrites the boot block, highest risk) | us; Forbidden-Darkness |
| Secure Boot | P2/P3 dumps: stack stripped (no DXE, vars or TPM). Check whether other builds (P5.00_clv) ship it | us, `bios_flashing/`; clevocore (P5.00_clv, Discord) |
| Secure Boot | ACPI fixes in the BIOS instead of the initrd override | Forbidden-Darkness |
| Secure Boot | SMU access from a signed kernel module, not userspace | filippor/cyan-skillfish-governor |
| Secure Boot | Sign the KMPs (OBS project key + MOK) | us, `home:superppl:bc250` |

Governor contribution candidates (filippor): D-Bus policy scoped to `com.cyanskillfish.Governor` (our patch); unit `WantedBy=multi-user.target`; `Cargo.toml` says `0.4.0` at tag v0.4.14.

**Not in mothenjoyer69/bc250-documentation (HEAD `7d4ce61`), candidate additions:** wall-power ladder and memory-profile effect; profile 1 hang; no RAPL / CPU rail in `gpu_metrics`; SMU feature mask and the MGCG hang; ASPM state and the NVMe x2 Gen2 link; s2idle/ACPI gaps; lockdown impact; 8-core needs a warm reboot; `nct6687` fan2 is the cooler fan. Their README still points to oberon-governor and the 24 CU / 6-core layout.

## Sensors

- hwmon: `nct6686` (via `nct6683`), `amdgpu`, `k10temp` (Tctl only), `nvme`. `nct6686` channels are unlabeled; none is a 12 V input or current sense.
- `nct6687`: fan2 is the cooler fan (Arctic P12, ~1960 rpm max). BIOS curve idle PWM 178 ≈ 1500 rpm; `pwm2_enable=2` returns to it. The `chip ID 0xffff` line is the empty `0x4e` probe.
- **VRAM temperature** via pan-Rijovich (`discovery/vram-temp/vramtemp-pan-rijovich.sh`, governor stopped): 8 chips, idle 28-38 °C. Loads a payload into SMU RAM after a Queue 2 `0x23` exploit; undone by a power cycle; second read in the same power cycle needs `SKIP_PATCH=1`. Control Center is the only single-reader route (flock, 5 s governor rule). Hexxeh's DKMS bypasses the flock and needs an unlocked gate. Reads use the GDDR6 bus and can crash.
- **8-core `gpu_metrics` layout is wrong on 7.3:** `current_gfxclk`, `pp_dpm_sclk`, hwmon `sclk` read 2-100 MHz; `temperature_core[0..3]` hold power. higorprado's `0001-bc250-8core-telemetry.patch` (GabriWar repo, no license header) fixes gfxclk; `average_*` stay wrong. 8-core repacks the first 0x46 bytes of the Current block: CoreFrequency[8], CorePower[7] at 0x10, CoreTemperature only cores 4-5 at 0x2C — so `temperature_core[0..3]` = core 6/7 power, `current_gfxclk` = core 6 C0 residency; cores 0-3/6/7 temps absent. Fields ≥0x46 unchanged. Real gfxclk: Q0 `0x37`.
- **amdgpu sysfs reads message the SMU** on Q0 (`0x03B10A08`) outside the governor's control. The governor's bind-mounted `gpu_metrics` copy does not.
- Board PMICs ISL69247/ISL95712/ISL99360 (mothenjoyer69 `hardware.md`). ISL69247 PMBus needs jumper wires from `I2C_HEADER1` to `TPMS1` pins 4/6 (onlinermm).

## Host state

- systemd-boot (`sdbootutil`). Kernel `7.3.0-1-default`, LVM + btrfs, SELinux. CPU family 23 model 71; root complex `1022:13e0`; GPU `card1` (`1002:13fe`).
- BIOS P3.00 Chipset Menu (flashed from P2.00, ranges in `bios_flashing/flash.layout`, readback matched). IOMMU off. 14 GiB RAM visible. No `fwupd` system firmware device.
- P3.00 vs P2.00 dump diff: only ABL `33.17.9`→`33.17.38` (bodies changed in ABL2/ABL4) and one Setup ref repointed to CBS "NBIO Common"; no setting defaults or APCB values changed.
- CPU microcode `0x08407007`; `ucode-amd-20260926` has no patch for CPUID `0x840F70`. AGESA `RBNBDK-BL5 46.1.2.220426` (community P5clv ROM; not exposed live).
- PSP `01:00.2 [1022:143e]` has no driver and is disabled; amdgpu loads no PSP firmware (SOS/TA 0). MSR reads work (PSP base MSR `0xC00110A2` = `0xFDD00000`); PPIN read `#GP`. BIOS sets SME enable (SYSCFG bit 23) but kernel SME is off; SEV/SEV-ES disabled; SMM locked.
- `CONFIG_ACPI_TABLE_UPGRADE=y`, debugfs mounted, `MODULE_SIG_FORCE` off, lockdown `none`.
- `osc` installed and authenticated; local builds via `sudo /usr/bin/build` (`/etc/sudoers.d/osc-build`).
- Test extras: `clpeak`, `Mesa-libRusticlOpenCL`, `libOpenCL1`, `libclc`; `/usr/local/sbin/bc250-memprofile-step2`. Logs `/var/log/bc250-vramtemp/`, `/var/log/bc250-memprofile-soak.log`.
- Community clones (HTTPS): `~/Code/bc-250-community-repos/`.

## Safety warnings

- **SMU contention.** Governor, 8-core unit and every SMU tool share `0xB8`/`0xBC` on `00:00.0`. Stop the governor before any SMU access; restart after.
- **SMU hang** (MGCG enable): every queue stops answering; only a power cycle recovers.
- **`bc250_detect.py` is not read-only**: applies an SMU state, writes `overclock.conf`.
- **Unknown core masks** (`0xD7`, `0x7D` exist): both scripts refuse anything but the expected value.
- **Unlocks are volatile**: cold boot reverts 8-core, memory profile and SMU features; warm reboot keeps 8-core.
- **One sensor driver**: `nct6683` and `nct6687` conflict.
- **40 CU patch upstream is archived**; we carry the rebase. A kernel that moves the hunk fails `%prep`; a newer kernel without a rebuilt KMP boots in-tree `amdgpu` (24 CU).
- **40 CU loads from the initrd.** Rollback: `/etc/modprobe.d/50-bc250-40cu.conf` with `options amdgpu bc250_cc_write_mode=0` + `dracut -f --regenerate-all`, or `amdgpu.bc250_cc_write_mode=0` on the cmdline, or remove the KMP.
- **ACPI tables load from the initrd.** If boot breaks, pick an older entry or snapshot, remove `bc250-acpi-tables`.
- **Flashing**: `flashrom -p internal` has no firmware-side check; a hardware programmer (CH347 or Pi Pico) on `BIOS_A1` is the only guaranteed recovery.

## Licenses

| Project | License |
| --- | --- |
| filippor/cyan-skillfish-governor | MIT |
| Fred78290/nct6687d | GPL-2.0 |
| GabriWar/bc250-core-cu-unlock | MIT (ROMs: none) |
| e-tho/bc250-acpi-fix | MIT |
| rw-r-r-0644/bc250-core-unlock | MIT |
| pan-Rijovich/bc250-memory-temperature | MIT |
| Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script | GPL-3.0 |
| fanoush/bc250_memcfg | MIT |
| tomstdenis/umr | MIT |
| duggasco/bc250-40cu-unlock | GPL-2.0 (README) |
| WinnieLV/bc250-cu-live-manager, mendesrr/bc250-acpi-fix-updated-8c | **none**: not redistributable |
| this repo | MIT, except `src/bc250-amdgpu/bc250-40cu-amdgpu.patch` (GPL-2.0) |

## Open questions

- Memory profile 2: full soak (38 min, 0 errors so far); does a warm reboot keep it; package as an opt-in one-shot unit?
- ASPM: persist `powersupersave` + NIC L1 (~2 W)?
- SMU DS_LCLK, DS_MP0/1/3CLK: untried; the first four gave nothing.
- VRAM temperature: continuous reader service, or Control Center? Holds under load?
- 8-core telemetry patch in `bc250-amdgpu`? Needs a KMP build, live check, and the patch's license.
- Fan curves: switch `bc250-setup` to `nct6687` and pick a curve tool (CoolerControl in OSS)?
- `bc250-telemetry-log` (`src/bc250-telemetry-log/`, 32 tests): publish? Does the governor's bind mount reach its sandbox?
- GFX CGCG opt-in patch (`discovery/clock-gating/`, never booted): low priority.
- Name the undocumented SMU IDs: disassemble the plaintext SMU blob (BIOS `0x8ff000`) or dump the Q3 handler table at SMU SRAM `0x7464` (needs the `0x28-0x2C` gate open). Blind probing risks SMU hangs.

## Sources

- elektricm docs: https://elektricm.github.io/amd-bc250-docs/ (governor, 40cu-unlock, 8core-unlock, sensors, power, stability, bios/flashing, bios/vram)
- https://www.skillfishos.com/en/docs/hardware-bc250/
- https://github.com/mothenjoyer69/bc250-documentation (`hardware.md`)
- https://github.com/lorek123/bc250-notes (DSDT dump)
- https://github.com/filippor/cyan-skillfish-governor (branches `smu`, `memory-profile`)
- https://github.com/GabriWar/bc250-core-cu-unlock (issue #1, PR #2, `bios/`, `kernel/patches/0001-bc250-8core-telemetry.patch`)
- https://github.com/rw-r-r-0644/bc250-core-unlock
- https://github.com/Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script
- https://gitlab.com/TuxThePenguin0/bc250-bios
- https://github.com/e-tho/bc250-acpi-fix
- https://github.com/mendesrr/bc250-acpi-fix-updated-8c
- https://github.com/duggasco/bc250-40cu-unlock (archived; `docs/technical-report.md`)
- https://github.com/WinnieLV/bc250-cu-live-manager
- https://github.com/fanoush/bc250_memcfg
- https://github.com/Fred78290/nct6687d
- https://github.com/pan-Rijovich/bc250-memory-temperature
- https://github.com/Hexxeh/bc250-memory-dkms, https://github.com/Hexxeh/bc250-vrm-dkms
- https://github.com/onlinermm/BC250-Telemetry
- https://github.com/movacx/bc250-control-center
- https://gitlab.freedesktop.org/tomstdenis/umr, https://build.opensuse.org/package/show/hardware/umr
- Kernel: `smu11_driver_if_cyan_skillfish.h`, `smu_v11_8_pmfw.h`, `cyan_skillfish_ppt.c`, `amd/pmc/pmc.c`, `amdgpu_acpi.c`
- https://build.opensuse.org/project/show/home:superppl:bc250
- bc250-unofficial-community-guide: `06-gpu-governor.md`, `02-bios-and-firmware.md`, `03-power-supply-guide.md`
