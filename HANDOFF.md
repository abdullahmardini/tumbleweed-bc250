# BC-250 handoff

Status: nothing decided, nothing implemented, nothing verified on this host.
Goal: run the BC-250 on openSUSE Tumbleweed with packages built in the openSUSE Build Service (OBS), contributing upstream where AI contributions are accepted.

## Safety warnings

From the sources below; none verified on this board yet.

- **SMU contention.** `cyan-skillfish-governor-smu` drives the same PCI index/data pair (`0xB8`/`0xBC` on `00:00.0`) as the 8-core unlock. Stop the governor before any SMU access, reads included. Restart after.
- **`bc250_detect.py` is not read-only.** It applies an SMU state and writes `overclock.conf` as a side effect. Never use it as a status check.
- **Unknown core masks.** Stock mask at SMN `0x0115A870` is usually `0x77`, but boards reading `0xD7` exist. Refuse to act on any mask that isn't the expected value.
- **Unlocks are volatile.** Cold boot reverts both the 8-core and 40 CU unlocks; warm reboot keeps them. Nothing is flashed, so pulling power is the rollback.
- **One sensor driver.** In-kernel `nct6683` and out-of-tree `nct6687` conflict. Load one, blacklist the other.
- **40 CU kernel patch is dead.** `duggasco/bc250-40cu-unlock` is archived and will not track new kernels.

## Sources

- https://elektricm.github.io/amd-bc250-docs/system/governor/
- https://elektricm.github.io/amd-bc250-docs/system/40cu-unlock/
- https://elektricm.github.io/amd-bc250-docs/system/8core-unlock/
- https://elektricm.github.io/amd-bc250-docs/system/sensors/
- https://elektricm.github.io/amd-bc250-docs/system/power/
- https://github.com/filippor/cyan-skillfish-governor (branch `smu`)
- https://github.com/duggasco/bc250-40cu-unlock (archived)
- https://github.com/WinnieLV/bc250-cu-live-manager
- https://github.com/GabriWar/bc250-core-cu-unlock
- https://github.com/mendesrr/bc250-acpi-fix-updated-8c
- https://github.com/e-tho/bc250-acpi-fix
- https://github.com/Fred78290/nct6687d
- https://build.opensuse.org/project/show/home:superppl
