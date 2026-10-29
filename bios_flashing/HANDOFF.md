# BC-250 BIOS / SMU handoff

Offline work on the dumps in this directory: what the firmware contains, what
was verified, what to do next. Board state lives in the top-level `HANDOFF.md`.

Status 2026-10-28: tooling done, image inventory done, CBS power options
located, reachability not yet proven. Nothing has been flashed.

## Goal

Two levers, in order of value:

1. Boot-time firmware settings for the power savings this repo currently gets
   from runtime SMU writes (memory profile 2, ASPM, SMU features). Firmware
   settings survive cold boot; runtime state does not.
2. Upstream: a power page for the Forbidden-Darkness UEFI menu project, or at
   minimum the offset table it needs.

Separately, the `_S3`/LPS0 path for suspend is firmware-side but belongs to
`e-tho/bc250-acpi-fix`, not to a menu change. See the top-level handoff.

## Verified

All of this is from `bios-backup-1.rom` (P2.00) and
`BC250_3.00_CHIPSETMENU.ROM`/`readback.rom` (P3.00), reproduced with
`romtool.py`.

- Three volumes: NVRAM `0x0` (128 KiB), DXE `0xae0000` (3.125 MiB, one LZMA
  container), PEI `0xe00000` (2 MiB). 186 DXE files, 27 PEI files.
- `Setup` `899407d7-99fe-43d8-9a21-79ec328cac21` holds the AMI forms;
  `CbsSetupDxe` `f639d37e-02a1-4ba8-ad17-5c6c6e5e9322` holds the AMD CBS forms
  and their UTF-16 help text.
- P2.00 vs P3.00: 10 modules differ. `Setup` differs by 67 bytes — AGESA string
  `46.1.0.211015` → `46.1.2.211126`, the build time, one flag byte (PE `0x72d`,
  `0x02` → `0x03`) and an IFR insert at `0x11fee` (`05 70 00 00` ONE_OF plus
  GUID `e33545b0-0430-4649-9eb7-149428983053`). *verify on host*: that insert
  is the Chipset Menu.
- `CbsSetupDxe` contains, as live forms with help text:
  - `Memory Clock Speed`, choices include 450, 850, 1750 MHz — the same three
    values the runtime SMU `0x1E` profiles produce.
  - the `SMU Features` bit menu: DS_GFXCLK, DS_SOCCLK, DS_LCLK, DS_SMNCLK,
    DS_MP0/1/3CLK, DS_SHUBCLK, CORE_CSTATES, SMU CG (MGCG), GFX_CKS, PROCHOT,
    CPUOFF, UMC/DF_THROTTLE, DLDO, STAPM, FP_THROTTLING, DFLL_BTC_CALIBRATION.
  - fPPT/sPPT plus time constant, TDC/EDC, TctlMax, PROCHOT deassertion.
  - GDDR6: Power Down enable/mode/delay, aggressive power down, `Phy Power
    Saving`, `Memory P-state`, `Gear Down Mode`, fixed/OTF refresh, all-CKE.
  - fabric: DF Cstate clock power down / self refresh / GMI / xGMI power down,
    `DF clock gating control` (`PwrMgtCfg0[ClkGateDis]`), DF picker load step,
    PC6 hint propagation.
  - NBIO: `MMHUB Light Sleep`, ATHUB/IOHC/IOMMU clock gating, NBIF and SHUB
    MGCG.
  - PCIe, per port: `Link ASPM` (L0s and L1), phy/PLL poweroff in L1, memory
    power shut down / deep sleep in L1.
  - `GFX CUs/RB` → `InactiveCUs`; VDDCR_VDD and VDDCR_GFX voltage offsets.
- CBS values live in the `AmdSetup` and `Setup` NVRAM variables;
  `CbsSetupDxe` formats `GUID=…&NAME=…&PATH=…&OFFSET=0&WIDTH=…`, so a value is
  addressable as variable + offset.
- SMU firmware is plaintext at `0x8ff000` (16-byte header, `$PS1` entry), the
  same offset in both images.

## Decisions

- Analyse the dumps; do not reflash for experiments. A hardware programmer is
  the only recovery, and the `_S3`/ASPM/power defaults can all be reached
  without it (initrd ACPI override, NVRAM, or a menu patch tested once).
- Where a firmware knob exists, prefer it over a runtime SMU write: cold boot
  reverts runtime state, and the userspace SMU lock is per 32-bit access, so
  tools can corrupt each other's messages.
- Do not patch DXE bytes to unhide forms before the IFR walk says which forms
  exist. Unhiding a dead string produces a menu entry that writes to nothing.
- A defaults writer (variable + offset) before a form patch: it is smaller,
  testable one option at a time, and does not depend on how the Chipset Menu
  insert works.

## Rejected

| Option | Why |
| --- | --- |
| Trust the stored FV header length / checksum | Both are wrong in these images; parsing produced zero files. |
| Grep the raw image for CBS text | The DXE volume is LZMA-compressed; all CBS strings live inside it. |
| Reflash a patched full image to try one setting | No firmware-side check, hardware programmer required to recover. |
| Reuse the 8-core/memory-profile payload path for settings that fit in NVRAM | Adds an SMU race and dies on cold boot. |
| Expose the whole `SMU Features` page | MGCG is on the same page and hangs the SMU until power-off. |

## Next

1. IFR/HII walk of `CbsSetupDxe`: form package → question ID → varstore
   (guid, offset, width) → value map. This is what turns the string list into a
   settings table, and it is fully offline.
2. Disassemble around the `Setup` insert at PE `0x11fee` to confirm the Chipset
   Menu mechanism and whether a new page can be added the same way.
3. Publish the power-option table (option, var, offset, width, values,
   measured or expected effect) — this is the upstream contribution on its own.
4. Decide delivery: NVRAM defaults writer, or form patch, or both.
5. Board tests, one option at a time, cold boot between: memory clock 850
   first (17 W already measured behind it), then `Link ASPM` L0s+L1, then DF
   C-states, then NBIO clock gating. MGCG never.

## Open questions

- Are the CBS power forms reachable, or dead strings? Needs the IFR walk.
- Is `Memory Clock Speed` the same knob as SMU `0x1E`, and does setting it in
  firmware keep the boot-time DRAM clock at 850 (runtime profiles revert on
  cold boot, and profile 1 hung the board under load)?
- Does the 40 CU `InactiveCUs` option do what the KMP patch does? Would remove
  a kernel module and the 24 CU fallback.
- Which of the NBIO/DF clock-gating options are safe with the GPU's own CG
  disabled by the driver (`nv.c` sets `cg_flags = pg_flags = 0` for GC 10.1.3)?
- Do any of these survive "load setup defaults", or does a defaults writer have
  to run every boot?

## Safety

- `flashrom -p internal` has no firmware-side check. CH347 or Pi Pico on
  `BIOS_A1` is the only guaranteed recovery.
- Keep `readback.rom` and the P2.00 dumps; they are the reference for every
  module diff and for restoring the board.
- Never flash a modified image that has not been read back and compared.
- Nothing in this directory writes an image. `romtool.py` opens files read-only;
  `extract` writes only to the output directory it is given.

## Commands used for the claims above

```sh
uv run python -m unittest discover -s tests
uv run romtool.py list readback.rom | head
uv run romtool.py diff bios-backup-1.rom readback.rom
uv run romtool.py grep readback.rom '$PS1'
uv run romtool.py vars readback.rom | grep -E 'Setup|AmdSetup'
```
