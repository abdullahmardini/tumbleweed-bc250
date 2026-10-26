# BC-250 handoff

Status: all six packages built in `home:superppl:bc250`, none installed on the board yet. BIOS is P3.00 Chipset Menu with a 512 MB VRAM split. The 8-core unlock was reverted by the post-flash cold boot.
Goal: run the BC-250 on openSUSE Tumbleweed with packages built in the openSUSE Build Service (OBS), contributing upstream where AI contributions are accepted.

## Decision

Option 3: a small OBS project plus one `bc250-setup` meta RPM. Setting up a host is `zypper ar` + `zypper in bc250-setup`; `zypper dup` keeps it current.

- One package per piece: governor, `umr`, the 40 CU script, ACPI tables, the 8-core script.
- `bc250-setup` depends on them. It ships the sensor config, the suspend block and a systemd preset. Its only scriptlet is one `systemctl preset` on first install: the unit packages install first and preset their units before the preset file exists.
- The preset enables the governor and the 8-core unit. The 40 CU unit ships disabled until the runtime route is verified on this board (see 40 CU).
- Per-board values (voltage curve, CU layout) stay in this repo.

Build order. Each step is usable on its own; finish one before starting the next.

1. Governor RPM, installed with `zypper` and running.
2. `umr` package and the 40 CU script, capped at 1500 MHz / 900 mV.
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
| 40 CU via DKMS or a patched kernel | The patch modifies `amdgpu` itself, so every Tumbleweed kernel bump means rebuilding the GPU driver. Its repo is archived. DKMS compiles on the host. A patched `kernel-default` in OBS means maintaining a kernel. |
| Shipping WinnieLV's live manager | No license. `bc250-40cu` in `src/` is our own script built from the published register values. |
| Masking sleep targets from a package | `/etc` is admin territory. A `sleep.conf.d` drop-in in `/usr/lib` does the same and can be overridden. |

## The pieces

| Piece | What it is | Package |
| --- | --- | --- |
| Governor | GPU clocks and voltage, the main GPU power saving | `cyan-skillfish-governor-smu` |
| 40 CU | GPU register writes after boot, through `umr` | `umr` (linked from OBS `hardware`), `bc250-40cu` |
| 8-core | SMU message `0x98` sets the core mask | `bc250-8core-unlock` |
| Sensors | Reading only needs `options nct6683 force=1`. `nct6687` is only for software fan curves. | Config in `bc250-setup` |
| Power | CPU idle and frequency states come from ACPI tables. The governor covers the GPU; its voltage curve is the undervolt. | `bc250-acpi-tables` |
| Suspend | Blocked: the board never wakes from s2idle | Config in `bc250-setup` |

## OBS packages (`home:superppl:bc250`, built 2026-10-26)

| Package | Source | Notes |
| --- | --- | --- |
| `cyan-skillfish-governor-smu` | tag v0.4.14 (`7b08fdc`), crates vendored with `cargo_vendor` | 37 tests pass in `%check`. Carries `dbus-policy-scope-to-destination.patch` (below). rpmlint `dbus-file-unauthorized` stays until the SUSE security team whitelists the policy; that only matters for Factory. |
| `umr` | `osc linkpac hardware umr` (1.0.11, MIT) | 1.0.11 has `cyan_skillfish.asic` and all three 40 CU registers in `gc_10_1_0.reg`. |
| `bc250-40cu` | `src/bc250-40cu` and `src/bc250-40cu.service` | Unit `Requires=` the governor. |
| `bc250-8core-unlock` | GabriWar commit `c532536`, script and LICENSE only | The upstream tree also ships BIOS images, so the archive is not used. Our unit runs `boot` `Before=` the governor. |
| `bc250-acpi-tables` | e-tho/bc250-acpi-fix v1.1.1, built with `iasl` | Drop-in `/usr/lib/dracut/dracut.conf.d/50-bc250-acpi.conf` sets `acpi_override` and `acpi_table_dir`. `%regenerate_initrd_post` rebuilds the initrd; suse-module-tools' posttrans calls `sdbootutil` on systemd-boot, so no loader entry edits. |
| `bc250-setup` | `src/bc250-setup/` | Preset logic verified offline with `systemctl --root`: governor and 8-core enabled, 40 CU disabled. |

## 40 CU

`umr` is AMD's User Mode Register debugger (`tomstdenis/umr` on freedesktop GitLab). It reads and writes `amdgpu` registers through debugfs (`/sys/kernel/debug/dri/<N>/`), needs root, and is ordinary userspace C, so it does not track the kernel.

Registers, per shader array (SE0-1 × SH0-1), from duggasco's technical report:

| Register | Stock | Unlocked | Role |
| --- | --- | --- | --- |
| `CC_GC_SHADER_ARRAY_CONFIG` | `0xfff80000` | `0xffe00000` | Enumeration: how many CUs the driver reports |
| `SPI_PG_ENABLE_STATIC_WGP_MASK` | `0x7` | `0x1f` | Dispatch gate: which WGPs receive waves |
| `RLC_PG_ALWAYS_ON_WGP_MASK` (global) | | `0x1f` | Set alongside SPI by duggasco and WinnieLV |

**The runtime route is unverified.** amdgpu reads `CC_GC_SHADER_ARRAY_CONFIG` once, at driver init. duggasco's 4-state test shows SPI `0x1f` with stock enumeration gives no compute gain (302 → 302 tok/s); the 1.61× needs both. The published speedups all use the patched kernel, which writes CC at init. WinnieLV's live manager and elektricm's "Option 4" write CC after init, which does not change the topology the driver already cached. Whether games or Vulkan compute still gain is untested. Measure before and after on this board.

The registers use debugfs MMIO, not the SMU mailbox, so the writes do not contend with the governor.

Performance, from the elektricm 40 CU page (duggasco A/B/A test, patched kernel, stock cooler); not measured on this board:

- **Compute:** Vulkan `llama-bench` pp512 at 1500 MHz, 230 → 372 tok/s (1.61×, theoretical 1.67×), 95 → 125 W, 79 → 83 °C.
- **Graphics:** the page's only number is `glmark2` +4.4%, and it says graphics is not widely tested. glmark2 is CPU/driver-bound, so it understates gaming. YouTube game benchmarks (reported by the user, not linked) show about +30%.
- **Thermals at 2 GHz, sustained:** CPU 100 °C (TJmax), PPT peak 220-230 W, GPU edge peak 107 °C, throttles within minutes. The page recommends 1500 MHz / 900 mV. Run the governor before unlocking.

## Suspend

Verified read-only on this board (2026-10-25); kernel logs were unreadable because the user is not in `systemd-journal`:

- `/sys/power/mem_sleep` offers only `[s2idle]`. The DSDT (same on BIOS 1.00-5.00, public dump in lorek123/bc250-notes) has `_S0`, `_S4`, `_S5`, no `_S3`, and no LPS0 device (`PNP0D80`).
- No `amd_pmc` device: the driver matches AMDI0005-000C/AMD0004-5, and the board has none.
- amdgpu skips its suspend path without the FADT `LOW_POWER_S0` flag, so the GPU stays up through s2idle. With no cpuidle driver the CPUs only `HLT`.
- The ACPI SCI and every GPE counter read 0 for the boot, so wake delivery is unproven.
- Community reports (elektricm troubleshooting, SkillFishOS) match: enters s2idle, never wakes, only a power cut recovers. No known fix; the ACPI tables do not claim to fix it.
- GNOME's default idle action on AC is `suspend` after 900 s. `bc250-setup` ships `AllowSuspend=no` / `AllowHibernation=no`, so logind reports `CanSuspend=na` and GNOME stops offering it.

## Host state (checked 2026-10-25, read-only, no SMU access)

- Bootloader is **systemd-boot** (`LOADER_TYPE="systemd-boot"`, `sdbootutil` present, no `grub2-mkconfig`). GRUB-based ACPI delivery does not apply.
- Kernel `7.3.0-1-default`, root on LVM + btrfs snapshots, SELinux enabled on cmdline. `amdgpu` loaded; no `nct668x` module and no modprobe/modules-load config.
- CPU family 23 model 71 (0x47); root complex `1022:13e0`.
- 6 cores / 12 threads after the post-flash cold boot. The 8-core unlock worked before that (8 / 16 visible). Its hand-installed unit was removed with the script's `uninstall` verb, so nothing writes the SMU at boot.
- GPU is `card1` (`1002:13fe`, `amdgpu`).
- BIOS `P3.00` Chipset Menu (2021-12-09), flashed 2026-10-25 from `P2.00`. UMA Frame Buffer 512M, IOMMU disabled. `mem_info_vram_total` 512 MiB, 14 GiB RAM visible (was 8192 MiB / 7.5 GiB).
- No `svm` flag in `/proc/cpuinfo` and no `/dev/kvm`: SVM is off in BIOS setup. Local `osc build` uses chroot via `sudo /usr/bin/build` (NOPASSWD in `/etc/sudoers.d/osc-build`).
- `fwupdmgr get-devices` lists no system firmware device (only CPU, GPU, NVMe). The board has no UEFI capsule update path, so `fwupdmgr` cannot flash its BIOS.
- `CONFIG_ACPI_TABLE_UPGRADE=y`, `CONFIG_DEBUG_FS=y` and mounted, `MODULE_SIG_FORCE` not set. Secure Boot disabled (firmware reports unsupported). Lockdown `none`.
- No `cpuidle` and no `cpufreq` in sysfs: stock firmware exposes no C-states or P-states, so the ACPI tables are needed.
- hwmon shows `nvme`, `amdgpu`, `k10temp` only. No board sensor driver is loaded. `nct6683` has a `force` parameter.
- Not installed: `sensors`, `coolercontrol`, `umr`, governor. `osc` is installed and authenticated (keyring).
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
| this repo | MIT (`LICENSE`) |

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
- **Unknown core masks.** Stock mask at SMN `0x0115A870` is usually `0x77`, but boards reading `0xD7` exist. Refuse to act on any mask that isn't the expected value. Both packaged scripts refuse.
- **Unlocks are volatile.** Cold boot reverts both the 8-core and 40 CU unlocks; warm reboot keeps them. Nothing is flashed, so pulling power is the rollback.
- **One sensor driver.** In-kernel `nct6683` and out-of-tree `nct6687` conflict. Load one, blacklist the other.
- **40 CU kernel patch is dead.** `duggasco/bc250-40cu-unlock` is archived and will not track new kernels.
- **ACPI tables load from the initrd.** If a table breaks boot, pick an older entry or snapshot in systemd-boot, then remove `bc250-acpi-tables`.

## Open questions

- Does the runtime 40 CU route speed anything up on a stock `amdgpu`? Test with a Vulkan benchmark before and after `bc250-40cu apply`.
- Does `umr -b <se> <sh> x -r '*.*.mmSPI_PG_ENABLE_STATIC_WGP_MASK'` resolve on this board, and what does its output look like? `bc250-40cu` parses the last hex word; only tested against a fake `umr`.
- Where does the 1500 MHz cap for 40 CU live? The governor's `/etc` config is `%config(noreplace)` and owned by the governor package.

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
- https://github.com/filippor/cyan-skillfish-governor (branch `smu`)
- https://github.com/duggasco/bc250-40cu-unlock (archived; `docs/technical-report.md`)
- https://github.com/WinnieLV/bc250-cu-live-manager
- https://github.com/GabriWar/bc250-core-cu-unlock
- https://github.com/mendesrr/bc250-acpi-fix-updated-8c
- https://github.com/e-tho/bc250-acpi-fix
- https://github.com/Fred78290/nct6687d
- https://gitlab.freedesktop.org/tomstdenis/umr
- https://build.opensuse.org/package/show/hardware/umr
- https://github.com/torvalds/linux/blob/master/drivers/platform/x86/amd/pmc/pmc.c
- https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/amdgpu/amdgpu_acpi.c
- https://build.opensuse.org/project/show/home:superppl:bc250
