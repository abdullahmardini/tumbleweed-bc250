# BC-250 BIOS tools

Read-only parsers for the SPI dumps in this directory. Stdlib Python, no
UEFITool, no network, no writes to any image.

## Dumps

Not committed (`*.rom` is git-ignored: copyrighted, and a backup carries board
settings).

| File | What it is |
| --- | --- |
| `BC250_3.00_CHIPSETMENU.ROM` | vendor P3.00, Chipset Menu build |
| `readback.rom` | readback after flashing, byte-identical to the file above |
| `bios-backup-1.rom`, `bios-backup-2.rom` | pre-flash P2.00 dump, identical to each other |
| `bios_sha256`, `layout.txt`, `flash.layout` | hashes, flashrom layout, region map |
| `flashrom-probe.log` | probe output from the dump run |

## Usage

```sh
uv run romtool.py list   readback.rom            # volume tree, FFS files, UI names
uv run romtool.py list   readback.rom --named    # only files with a UI section
uv run romtool.py extract readback.rom /tmp/x    # every file and section, decompressed
uv run romtool.py grep   readback.rom ASPM       # ASCII and UTF-16LE, with offsets
uv run romtool.py vars   readback.rom            # NVRAM variable store
uv run romtool.py diff   bios-backup-1.rom readback.rom
```

`extract` writes one directory per FFS file plus one per section; `meta.txt`
holds GUID, type, offset and the UI name. Read `meta.txt`, not the directory
name, when matching modules between images.

## Why the parser looks odd

All five points cost time to rediscover, and each one breaks a naive parser:

- The stored FV header length is wrong. At `0x0` the field says `0x48`; the FFS
  area starts at `0x78`. The tool tries every offset in the header window and
  keeps the one with the longest valid file chain.
- The PI header checksum is invalid in both images (at `0x0` it needs `0x39`,
  the image holds `0x4d`). Structure is validated instead. Do not "fix" the
  checksum on a copy you intend to flash without knowing where the image came
  from.
- The DXE volume at `0xae0000` is a container: one FFS file, one GUIDed LZMA
  section (`ee4e5898-…`), whose payload is `[RAW 12][FV 0x418000]`. The 186 DXE
  drivers live in the inner volume; the PEI volume at `0xe00000` holds 27.
- CBS menu text is UTF-16LE and lives inside that LZMA payload, so it is
  invisible to a plain `grep` of the image. `grep` handles UTF-16, but you still
  have to look at a decompressed module.
- The NVRAM store is AMI's `NVAR` format, not the PI variable store: no field
  gives a trustworthy record length, so records run to the next `NVAR`
  signature. Treat names and values as hints.

## Tests

```sh
uv run python -m unittest discover -s tests
```

22 tests: volume discovery, FFS walking, the LZMA container, decompression
failures, UTF-16 strings, the NVRAM walk, grep on the raw image versus the
decompressed module, the page diff, and the CLI argument handling. Tests that
need an image skip when it is absent.

## Scope

Nothing here flashes, writes, or validates an image for flashing. Findings and
the plan live in `HANDOFF.md`; the board-level safety rules live in the
repository's top-level `HANDOFF.md`.
