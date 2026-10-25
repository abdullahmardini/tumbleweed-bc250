# BC-250 configuration handoff

Status: decisions recorded, nothing implemented. Upstream governor `v0.4.14` audited for packaging on 2026-10-25; repo has no code yet.
Scope: how BC-250 platform tweaks are owned across the openSUSE Build Service (OBS) and this dotfiles repo.
Audience: future me, six months from now, on a fresh Tumbleweed install.

## Decision

Use a hybrid split:

- **OBS (`home:superppl:bc250`) owns software.** RPMs for the GPU governor, the `nct6687` kernel module, and the BC-250 userspace tools. Build once, install with `zypper`, upgrade with `zypper dup`, remove with `zypper rm`.
- **Dotfiles own policy.** Per-board voltage curves, fan curves, card index, modprobe/modules-load config, GRUB kernel arguments, ACPI cpio, service enablement, and target ordering live in this repo.
- **Structure follows option 2** (per-subsystem Make targets plus an aggregator), with **option 3** (script verbs `status` / `install` / `uninstall`) for the two SMU mutations, because those are not idempotent copy operations.
- **40 CU uses the runtime UMR route**, not the archived out-of-tree `amdgpu` kernel patch. Tumbleweed is a rolling kernel; a module rebuilt against 7.3 is guaranteed to break on the next bump, and the upstream patch repo is archived.

The Makefile never compiles software on the host and never edits the running SMU state as a side effect of an unrelated target.

## Options considered and rejected

| Option | Shape | Why rejected |
| --- | --- | --- |
| 1. Monolithic `make bc250` | One target, one directory | One target mutates initramfs, kernel modules, services and SMU registers. No partial rerun, no safe ordering, hard to debug. |
| 2. Per-subsystem targets | `bc250-*` targets + aggregate | Chosen for the general shape. |
| 3. Script verbs | `install` / `status` / `uninstall` per subsystem | Chosen only for 8-core and 40 CU, where rollback and status matter more than declarativeness. |
| 4. Pinned upstream scripts | Makefile fetches repos at fixed SHAs | Upgraded into the OBS plan: own the artifacts instead of invoking someone else's installer. Still rejected as the primary mechanism because reruns depend on upstream script behaviour. |
| 5. Ansible / Salt | Declarative host convergence | A second toolchain for one machine. Fights the repo's existing make-plus-copies model. |
| 6. OBS only | Everything as RPMs | Cannot express host policy: kernel cmdline, initramfs regeneration, service enablement, per-board curves. Also makes the 40 CU patch a kernel rebuild. |

## Platform findings

These are the constraints the implementation must respect. Every claim here comes from the upstream documentation listed at the bottom; verify the ones marked *verify on host* before relying on them.

### Kernel and distro

- Distro is openSUSE Tumbleweed. Every upstream install path is Fedora (`dnf` / COPR / `rpm-ostree`) or Arch (AUR); none applies.
- The governor's COPR (`filippor/bazzite`) is Fedora-only. On Tumbleweed the options are the release tarball (`.tar.gz`, `.deb` not usable) or `cargo build --release` from the `smu` branch.
- OBS repository URL: `https://download.opensuse.org/repositories/home:/superppl:/bc250/openSUSE_Tumbleweed/`.
- openSUSE GRUB regeneration: `grub2-mkconfig -o /boot/grub2/grub.cfg`; initramfs regeneration: `dracut -f`.
- Packages present in OSS: `sensors`, `coolercontrol`, `cargo`, `rust`, `libdrm-devel`, `pciutils`, `kernel-default-devel`, `cpupower`. No `umr` package and no `nct6687` package were found; confirm again at implementation time.

### GPU governor

- Recommended: `cyan-skillfish-governor-smu`, SMU backend, no kernel patch required on any distro.
- Latest upstream release: `v0.4.14` (2026-10-03). Source branch: `smu`.
- Service: `cyan-skillfish-governor-smu.service`.
- Config: `/etc/cyan-skillfish-governor-smu/config.toml`, section-based TOML (`[[safe-points]]`, `[frequency-range]`, `[temperature]`, `[gpu]`, `[gpu-usage]`, `[dbus]`). The older flat `safe-points = [...]` schema is obsolete.
- Config is read once at service start. Edits require `systemctl restart`. There is no reload.
- Minimum voltage 700 mV. Below that the GPU locks at 1500 MHz.
- Governor may target `card0` or `card1`; verify with `ls -la /sys/class/drm/`.
- `nct6683`/`nct6687` sensor config and the governor both touch hardware; load order does not matter, but only one fan-control module may be loaded.
- The 8-core unlock breaks `pp_dpm_sclk` reporting. The governor can overlay hwmon `freq1_input` with the real SMU clock via `[gpu-usage] fix-freq = true`; off by default.

### ACPI (C-states and P-states)

- Stock firmware exposes no usable C-states and no P-states. 6-core SSDTs from `bc250-collective` cover only 12 threads; 8-core boards need `mendesrr/bc250-acpi-fix-updated-8c`, which extends to all 16 threads.
- Maintained fork with three tables (CST, PST, STUBS): `e-tho/bc250-acpi-fix`. Modded BIOSes may inject their own tables; do not combine.
- Delivery is an early-initrd ACPI table upgrade. Two mechanisms:
  - cpio in `/boot` plus `GRUB_EARLY_INITRD_LINUX_CUSTOM` in `/etc/default/grub`, then regenerate GRUB.
  - dracut `acpi_override` with tables under `/etc/dracut.conf.d/acpi/`, then `dracut -f`.
- Requires `CONFIG_ACPI_TABLE_UPGRADE=y` (*verify on host*).
- Do not leave stray `.aml` files where the hook globs them; duplicates fail to load.
- Verification: `dmesg | grep -iE 'ACPI.*(SSDT|Table Upgrade)'`, `cpupower idle-info`, `cpupower frequency-info` (8 steps, 800 MHz to 3.2 GHz).

### Sensors (Nuvoton NCT6686D)

- In-kernel `nct6683 force=true`: read-only. Enough for temperature, voltage, and fan RPM.
- Out-of-tree `nct6687` (Fred78290/nct6687d): read plus PWM fan control. Required only for software fan curves.
- Both report as `nct6686-isa-0a20`. They conflict; blacklist the unused one.
- Persistence: `options nct6687 force=true` in `/etc/modprobe.d/sensors.conf`, `nct6687` in `/etc/modules-load.d/`, then `dracut -f`.
- PWM values do not persist across reboot. CoolerControl or a systemd unit must reapply them.
- Board has two physical fan headers; the primary fan typically reads as `Pump Fan`.
- BIOS fan modes: Default (too hot), Full Speed, Customize. Full Speed is the safe baseline before software control works.

### 8-core unlock

- Mask register: SMN `0x0115A870`. Stock `0x77` (cores 3 and 7 masked), unlocked `0xFF`.
- Written via SMU mailbox message `0x98` over PCI config index/data `0xB8`/`0xBC` on `00:00.0`.
- **The governor drives the same index/data pair.** Stop `cyan-skillfish-governor-smu` before *any* SMU access, including reads. Restart after.
- Warm reboot preserves the mask; cold boot reverts to `0x77`. Nothing is flashed, so pulling power is the safety net.
- Tool: `GabriWar/bc250-core-cu-unlock` (`status`, `apply`, `install`). Needs `pciutils` and root. `install` creates a systemd unit that re-applies after cold boot and **never reboots on its own**.
- Do not use `bc250_detect.py` as a read-only status check; it applies an SMU state as a side effect and writes `overclock.conf`.
- Not every board reads `0x77`; another board reported `0xD7`. Refuse to act on unknown masks.
- After unlocking: re-test all 8 cores (`test-cores.sh`), re-validate the voltage curve, and expect higher Tctl and worse load-line droop.
- ACPI tables must be swapped to the 8-core versions.

### 40 CU unlock

- Upstream `duggasco/bc250-40cu-unlock` is **archived** (2026-09-17). It still clones, but nothing will be updated for newer kernels.
- Two registers must change together: `CC_GC_SHADER_ARRAY_CONFIG` `0xfff80000` → `0xffe00000`, and `SPI_PG_ENABLE_STATIC_WGP_MASK` `0x07` → `0x1f`. The patched module also writes RLC.
- Kernel-patch route: rebuild `amdgpu` out-of-tree against the running kernel, install `amdgpu.ko.zst`, `options amdgpu bc250_cc_write_mode=3`, reboot. Reverts on every kernel update. Not viable on Tumbleweed without a pinned kernel.
- Runtime route: `WinnieLV/bc250-cu-live-manager` writes the same registers through `umr` after boot, provides a TUI, persists a layout to `/etc/bc250-cu-live-manager.conf`, and ships a systemd unit. Active project (last push 2026-07-30).
- Not every board tolerates all 40 CUs. Test per-WGP health before trusting sustained workloads.
- 40 CU is a compute unlock, not a gaming unlock (glmark2 +4.4%). Sustained 40 CU at 2 GHz on stock cooling throttles hard; cap at 1500 MHz / 900 mV.
- Graphics corruption after unlock means: mask suspect CUs or go back to 24.

### Power

- No separate power-limit knob. Power is governed by the GPU voltage/frequency curve plus ACPI P-states.
- Reference numbers: 105 W idle stock, 85 W with governor, 55-70 W with governor plus undervolt. Gaming 150-200 W; FurMark 250-320 W.
- 220 W official TDP, 300 W+ PSU headroom recommended, single 12 V rail.
- Undervolt procedure: drop 25 mV at a time, run a sustained load for 30+ minutes, step back up on instability.
- CPU undervolt is a separate SMU operation (`bc250_smu_oc`), not part of the governor. Experimental; out of scope for the first pass.

## OBS implementation

Subproject: `home:superppl:bc250`, repository `openSUSE_Tumbleweed` only. Keeping it separate keeps the existing `home:superppl` packages (`librespot`, `snapcast`, `thinkfan`) untouched and gives a stable repo URL.

### `cyan-skillfish-governor-smu`

- Source: `https://github.com/filippor/cyan-skillfish-governor` at tag `v0.4.14` (bump deliberately; a rolling governor on a rolling distro is how you get surprise regressions). HEAD of `smu` was exactly `v0.4.14` at audit time.
- Ship: binary, systemd unit, default config as `%config(noreplace)`, the `cyan-skillfish-performance-mode` script, the D-Bus policy file.
- Runtime deps: `libdrm` (auto-generated from the ELF).
- Do not ship a tuned curve here. The shipped config is a template; real values come from dotfiles.

#### Fork, do not PR the whole spec

Upstream targets Fedora: rust2rpm spec, three `deps/` split specs, `.packit.yaml` for COPR, `%autochangelog`. The openSUSE port replaces nearly all of it, so it would be churn, not portability. Fork it here and PR only the genuine bugs: the `# FIXME` Summary, the malformed `/bin/systemctl %name.service` in `%post`, and `%name` used as a macro.

#### Porting facts verified 2026-10-25

- Of the four upstream specs, only `cyan-skillfish-governor-smu.spec` is relevant. `deps/rust-ta.spec` and `deps/rust-watch.spec` are dead (`ta` and `watch` are absent from `Cargo.lock`). `deps/rust-libdrm_amdgpu_sys.spec` is obsoleted by vendoring. Drop `debian/` and `.packit.yaml` too.
- openSUSE `cargo-packaging 1.5.0` provides `%cargo_build`, `%cargo_test`, `%cargo_install`, `%buildsystem_cargo_*` only. There is no `%cargo_prep`, `%cargo_generate_buildrequires`, `%cargo_license`, `%cargo_license_summary` or `%cargo_install_lib`.
- OBS is offline during build and `%cargo_build` forces `--offline`. Vendor with the `cargo_vendor` source service (`obs-service-cargo 7.2.2` is in OSS) into `vendor.tar.zst`, extract with `%autosetup -a1`.
- `BuildRequires: cargo-packaging rust libdrm-devel systemd-rpm-macros`; use `%systemd_requires`. `cargo-packaging` pulls `cargo`, not `rust`. `libdrm-devel` does ship `libdrm_amdgpu.pc` and the unversioned `.so`.
- `%name` is not a macro on Tumbleweed rpm 4.20.1 (`rpm --eval '%name'` stays literal). Every `%name` in the spec must become `%{name}`.
- `%autochangelog` needs rpmautospec, which Tumbleweed does not package. OBS injects a `.changes` file as the RPM changelog; write it with `osc vc` and leave `%changelog` out.
- Version must be `0.4.14`, not `v0.4.6`. GitHub's tag tarball extracts to `cyan-skillfish-governor-0.4.14` (repo name, no `-smu`), so fix both the `Source` name and `%autosetup -n`.
- Export `CYAN_SKILLFISH_GOVERNOR_VERSION=%{version}` in `%build` and `%install`. `build.rs` falls back to `CARGO_PKG_VERSION`, which is `0.4.0` in `Cargo.toml`, so a tarball build without it misreports the version.
- Upstream tests are config-parser unit tests only, no hardware. `%check` is safe.
- Add `%dir %{_sysconfdir}/%{name}`; otherwise `/etc/cyan-skillfish-governor-smu/` is unowned.

### OBS tooling and git workflow

- `osc` (1.28.0 in OSS) is the only interface needed: `co`, `ci`, `build` (local chroot), `r`, `sr`, `vc`, `service run|remoterun`, `meta`. The `git-obs` CLI ships inside the same package (`/usr/bin/git-obs`) and is the Gitea/PR front end.
- Headless use: credentials in `~/.config/osc/oscrc`, or `OSC_USER` / `OSC_PASSWORD`. Everything is scriptable from a git hook or CI job.
- Two source models:
  - **srcserver + `_service`** (chosen). Sources live in OBS; the service file fetches the pinned tarball and vendors it server-side. One `osc ci` per change.
  - **`scmsync` SCM bridge.** `<scmsync>URL#ref</scmsync>` in package or project meta; `obs-scm-bridge` copies from git. Loses `_link` merging, needs explicit SR targets, does not transfer history. Push-to-build needs a notification, and the global bridge is gitea-only, so it is a poor fit on GitHub.
- Revisit `scmsync` only if the packaging repo moves to gitea/`src.opensuse.org`; the layout is then one top-level directory per package plus a `_config`.

### `nct6687-kmp`

- Source: `Fred78290/nct6687d` (active, last push 2026-10-19).
- Upstream is DKMS-shaped. A KMP needs a `Kbuild` file and `%kernel_module_package`; expect to carry a small patch.
- Benefit: rebuilds automatically against each `kernel-default` bump; signed; `zypper rm` removes it cleanly.
- Cost: KMP is built against the OBS `kernel-default`, which can lag the kernel you just booted by hours or days after `zypper dup`. Accept the lag. Do not add DKMS on top.
- Alternative if the KMP fights back: ship DKMS, accept local compilation, and add `kernel-default-devel` to `zypp-tools`.

### `bc250-tools`

- Contents: `GabriWar/bc250-core-cu-unlock` scripts plus its systemd unit, `WinnieLV/bc250-cu-live-manager` plus its unit and default `/etc/bc250-cu-live-manager.conf`, and `duggasco`'s `cu_map.sh` as a read-only diagnostic.
- `umr` may need to be packaged separately if it is still absent from OSS.
- No `%post` that touches the SMU, reboots, or rewrites initramfs. Units are installed but not enabled; enablement is a dotfiles decision.

### `bc250-acpi-tables`

- Data-only package: the 8-core `SSDT-CST.aml`, `SSDT-PST.aml`, and optionally `SSDT-STUBS.aml` from `mendesrr` / `e-tho`, plus a prebuilt `acpi_override.cpio`.
- No scriptlets. The package drops files under `/usr/share/bc250-acpi/`; dotfiles builds and installs the cpio and edits GRUB. This keeps the differing 6-core and 8-core table sets from ever both being live.

### OBS gotchas

- Public builds are fine; do not bake serials, board IDs, or per-board voltage values into specs.
- Record the upstream commit for every package in the changelog.
- The project already has one build error in the existing packages; do not let that mask new failures.
- Tumbleweed only. No Leap, no Slowroll, no Fedora.

## Dotfiles implementation

```
bc250/
  governor.toml              # curve, frequency range, fix-metrics, fix-freq
  modprobe-nct6687.conf      # options nct6687 force=true / blacklist nct6683
  modules-load-nct6687.conf
  acpi/build-cpio.sh         # aml -> cpio, refuses duplicates
  acpi/grub-fragment         # GRUB_EARLY_INITRD_LINUX_CUSTOM line
  cu/manager.conf            # saved WGP layout
```

Rules:

- Configs only. No vendored upstream source, no copies of upstream installer scripts.
- The governor curve is per-board. It lives here, not in the RPM.
- Every file that lands outside `$HOME` is copied by an explicit Make target, never by a package scriptlet.

### Makefile targets

```
bc250-repo      add/refresh the OBS repo
bc250-sensors   sensors + coolercontrol, modprobe config, dracut -f
bc250-governor  install package, copy governor.toml, enable + restart
bc250-acpi      build cpio, install to /boot, add GRUB line, regenerate GRUB
bc250-cores     bc250-8core status -> install (no automatic reboot)
bc250-cu        cu-map status -> write layout -> install unit
bc250           bc250-repo bc250-sensors bc250-governor bc250-acpi
```

- `bc250` deliberately excludes `bc250-cores` and `bc250-cu`. Both need a reboot and manual verification between steps; folding them into the aggregate target hides that.
- Every target is rerunnable. Package installs use `zypper in`, repo add uses `zypper ar -f`, GRUB and modprobe writes are guarded by `grep -q`.
- All targets carry `##` help text so `make help` keeps working.
- `bc250-repo` must use `zypper --gpg-auto-import-keys refresh bc250` or pin the repo key.

## Apply order

Run one step, verify, then continue. Do not batch steps 5-7.

0. **Recon, read-only**
   - `lscpu`, `ls -la /sys/class/drm/`, `cat /sys/class/drm/card*/device/device`
   - `mokutil --sb-state` (Secure Boot must be off for any out-of-tree module work)
   - `grep ACPI_TABLE_UPGRADE /boot/config-$(uname -r)`
   - `sensors` availability, PSU rating, cooling setup, BIOS fan mode
1. **Sensors** — `make bc250-sensors`
   - Verify: `sensors` shows `nct6686-isa-0a20`, fan RPM, `VRM MOS`, `Tctl`, `edge`, `PPT`.
2. **Governor** — `make bc250-governor`
   - Verify: `systemctl status cyan-skillfish-governor-smu`, `pp_dpm_sclk` moves between 1000 and the configured ceiling under load, `systemctl restart` picks up config edits.
3. **ACPI** — `make bc250-acpi`
   - Verify: `dmesg | grep -iE 'ACPI.*(SSDT|Table Upgrade)'` lists the tables; `cpupower idle-info` shows C1/C2 on all CPUs; `cpupower frequency-info` shows 8 P-states.
   - Do this before any 8-core work so the 8-core tables are the ones installed from the start.
4. **Power pass** — edit `bc250/governor.toml`, restart governor
   - Start at 1000-2000 MHz with the shipped curve. Undervolt 25 mV at a time. 30+ minute sustained load per step. Record the stable points in the repo.
5. **8-core** — `make bc250-cores`
   - Stop the governor first. `status`, then `install`, then a warm reboot that *you* trigger.
   - Verify: `lscpu` shows 8 cores / 16 threads, `bc250-8core status` reads `0xFF`, all 16 CPUs report C-states.
   - Re-run the health test and re-validate the curve. Expect higher Tctl.
6. **40 CU** — `make bc250-cu`
   - `cu_map.sh` first to record the harvest map. Then the live manager: write the layout, install the unit.
   - Verify: `dmesg | grep active_cu_number` shows 40, `RADV_DEBUG=info vulkaninfo` shows `num_cu = 40`.
   - Cap the governor at 1500 MHz / 900 mV for sustained work. Run the per-WGP health test before trusting it.
   - Rollback: disable the unit and cold boot. Cold boot always returns to 24 CU.

## Update and rollback

- After every `zypper dup`: `make bc250` (repo refresh reinstalls/upgrades packages), then check `lsmod | grep nct6687` and `systemctl status cyan-skillfish-governor-smu`.
- KMP missing after a kernel bump: wait for the OBS rebuild, or temporarily boot the previous kernel.
- Governor update: package upgrade keeps the existing `config.toml` (`noreplace`); diff against the new default before restarting.
- ACPI rollback: delete the cpio and the `GRUB_EARLY_INITRD_LINUX_CUSTOM` line, regenerate GRUB, reboot.
- 8-core rollback: `bc250-8core` unit disable, cold boot. A warm reboot keeps the unlocked mask.
- 40 CU rollback: disable the live-manager unit, cold boot (or explicitly restore the stock topology through the TUI).
- Never let a Make target reboot the machine.

## Risks

- **Kernel drift.** Tumbleweed 7.x moves faster than any of these projects. The governor is the safest (userspace, SMU), the KMP is next, the ACPI tables are data, and the 40 CU patch is the least future-proof; that is why it is runtime-only here.
- **KMP lag** after `zypper dup` leaves fan control or sensors missing for a while. BIOS Full Speed is the fallback.
- **Thermals.** 40 CU at 2 GHz exceeds the stock cooler. The repo default is a 1500 MHz ceiling; do not raise it without sustained-load data.
- **SMU contention.** Governor and 8-core tool use the same mailbox. A "quick read" while the governor is running can write the wrong register.
- **Two sources of truth.** Package defaults and dotfiles config will drift. The rule is: packages ship templates, dotfiles ship values.
- **Archived upstream.** The 40 CU kernel patch will not track new kernels. Treat it as unavailable, not merely inconvenient.

## Open questions

- Is Secure Boot actually off on the target board, and does Tumbleweed enforce module signatures?
- Does Tumbleweed's dracut support `acpi_override`, or is the GRUB cpio route the only one?
- Does the current Tumbleweed kernel expose `amdgpu` symbols needed by the 40 CU patch, if the patch route is ever revisited?
- Is software fan control actually wanted, or is BIOS Full Speed plus a fixed fan curve good enough? That decides whether the KMP is worth maintaining.
- Which DRM card index is the BC-250 on this install?
- PSU model and 12 V rail rating, plus current cooling setup; both gate the safe governor ceiling.
- Is `umr` packageable from OSS sources or does `bc250-tools` need to vendor it?
- Does `osc service remoterun` work on `build.opensuse.org` for this project (needed for headless service runs), or must services run locally before `osc ci`?
- Does the OBS `home:superppl:bc250` project still have that pre-existing build error, and does it block a new package being added?

## Sources

- https://elektricm.github.io/amd-bc250-docs/system/governor/
- https://elektricm.github.io/amd-bc250-docs/system/40cu-unlock/
- https://elektricm.github.io/amd-bc250-docs/system/8core-unlock/
- https://elektricm.github.io/amd-bc250-docs/system/sensors/
- https://elektricm.github.io/amd-bc250-docs/system/power/
- https://github.com/filippor/cyan-skillfish-governor (branch `smu`, release `v0.4.14`)
- https://github.com/duggasco/bc250-40cu-unlock (archived 2026-09-17)
- https://github.com/WinnieLV/bc250-cu-live-manager
- https://github.com/GabriWar/bc250-core-cu-unlock
- https://github.com/mendesrr/bc250-acpi-fix-updated-8c
- https://github.com/e-tho/bc250-acpi-fix
- https://github.com/Fred78290/nct6687d
- https://build.opensuse.org/project/show/home:superppl
