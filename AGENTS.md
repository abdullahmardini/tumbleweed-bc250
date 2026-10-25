# AGENTS.md

## Context

- Home user, one board: AMD BC-250 on openSUSE Tumbleweed.
- Unrecoverable files live on this machine. Do not modify the running system: no reboot, no SMU write, no GRUB/initramfs edit unless the user runs the target themselves.

## `bc-250-handoff.md`

The handoff is the decision record and platform reference, not a changelog and not a task list.

- Read it before proposing anything; it beats your assumptions.
- Records: what was decided, what was rejected and why, upstream facts with sources, apply order, risks, open questions.
- Update it when a **decision** changes, a platform fact is verified or corrected, or an open question is answered. Delete the question, don't append "answered above".
- Entries marked *verify on host* are unverified. Do not repeat them as fact.

## Communication

- Answer first. Bullets for lists. No narrative, no filler, no recap of what you just did.

## Style

- `set -euo pipefail` in scripts, not in functions. Literal paths, no silent failures.
- No magic numbers: name curves, ceilings and voltages.
- Comments explain why, not what.

## Hard rules

- Never compile software on the host.
- Never reboot.
- Never touch SMU state as a side effect: stop `cyan-skillfish-governor-smu` first.
- Packages ship templates, this repo ships values. Local file wins; copy it explicitly.

## Tests

Test success and failure paths. Verify with the commands in the handoff, not by assertion.

## Documentation

One README plus the handoff. No new markdown: no ADRs, no design docs, no changelog.
