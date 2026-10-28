# tumbleweed-bc250

Get an AMD BC-250 running on openSUSE Tumbleweed.
Aiming to be a single repo to get this thing going

Tumbleweed is just my preferred distro, I don't want to relearn muscle memory. `¯\_(ツ)_/¯`

## Layout

- `src/<package>/`: files that ship in an RPM, plus their tests (`tests/`, `*-tests.sh`). Specs live in OBS (`home:superppl:bc250`); `src/bc250-telemetry-log/` keeps its spec here because it is not on OBS yet.
- `discovery/<topic>/`: probes, experiments and patches used to work out what the RPMs should do. Nothing here is packaged. Scripts that write the SMU or PCI config say so in their header and need root.
  - `aspm/`: ASPM evidence capture and a one-link L1 A/B test
  - `memory-profile/`: idle baseline sampler, SMU memory-profile probe (step 1) and static set/soak (step 2)
  - `vram-temp/`: test for the Hexxeh `bc250-memory` module and its scratch OBS package
  - `gpu-metrics/`: `gpu_metrics` decoder, the 8-core telemetry patch and the spec diff to carry it
  - `clock-gating/`: opt-in `amdgpu.bc250_cg` patch, its check script and spec diff
  - `fan/`: nct6687 PWM test
- `bios_flashing/`: BIOS notes and tools
- `HANDOFF.md`: current state and open questions
