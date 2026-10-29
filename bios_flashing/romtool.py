#!/usr/bin/env python3
"""Read-only tooling for the BC-250 SPI dumps in this directory.

Stdlib only, no UEFITool. Subcommands:

  list   <rom> [--all]        firmware volumes, FFS files, names
  extract <rom> <outdir>      unpack every volume/file/section, nested FVs included
  grep   <rom> <pattern>      search strings (ASCII and UTF-16LE) with offsets
  vars   <rom>                walk the NVRAM volume, dump UEFI variables
  diff   <romA> <romB>        per-4K-page difference map

Notes that cost time to rediscover:

* The stored FV HeaderLength does not point at the FFS area in these images
  (base 0: field 0x48, first file 0x78), so `list` scores every start offset in
  the header window and keeps the one that yields the longest valid chain.
* The PI header checksum is invalid in both dumps (base 0 needs 0x39, holds
  0x4d). Structure is validated instead; do not "fix" the checksum on a copy
  you intend to flash without understanding where it came from.
* The DXE volume at 0xae0000 is a container: one FFS file holding one GUIDed
  LZMA section (EE4E5898-3914-4259-9D6E-DC7BD79403CF) whose payload is a section
  stream [RAW 12][FV image 0x418000]. `extract` recurses through that.
* The BC250_3.00_CHIPSETMENU.ROM vs bios-backup-1.rom diff is confined to a few
  pages; see `diff`, and README.md for what the Chipset Menu build carries.
"""

import signal
import lzma
import os
import struct
import sys
import uuid

FFS_HDR = 24
VALID_TYPES = set(range(0x01, 0x10)) | {0xF0}
TYPE_NAMES = {
    0x01: "RAW", 0x02: "FREEFORM", 0x03: "SEC", 0x04: "PEI_CORE",
    0x05: "DXE_CORE", 0x06: "PEIM", 0x07: "DRIVER", 0x08: "COMBINED_PEIM_DRIVER",
    0x09: "APPLICATION", 0x0A: "SMM", 0x0B: "FV_IMAGE", 0x0C: "COMBINED_SMM_DXE",
    0x0D: "SMM_CORE", 0x0E: "MM_STANDALONE", 0xF0: "PAD",
}
SECTION_NAMES = {
    0x01: "COMPRESSION", 0x02: "GUIDED", 0x03: "DISPOSABLE", 0x10: "PE32",
    0x11: "PIC", 0x12: "TE", 0x13: "DXE_DEPEX", 0x14: "VERSION",
    0x15: "USER_INTERFACE", 0x16: "COMPATIBILITY16", 0x17: "FV_IMAGE",
    0x18: "FREEFORM_SUBTYPE_GUID", 0x19: "RAW", 0x1B: "PEI_DEPEX", 0x1C: "MM_DEPEX",
}
GUIDED_TYPES = {0x01, 0x02, 0x03, 0x10, 0x11, 0x12, 0x18, 0x1B, 0x1C}
LZMA_GUID = "ee4e5898-3914-4259-9d6e-dc7bd79403cf"
FS_GUID = "8c8ce578-8a3d-4f1c-9935-896185c32dd3"  # FFS2; FFS3 is 5473c07a-3dcb-4dca-bd6f-1e9689e7349a


def guid(b):
    return str(uuid.UUID(bytes_le=b))


def align4(n):
    return (n + 3) & ~3


# ---------------------------------------------------------------- volume / file

def find_fvs(data):
    """Phantom '_FVH' hits exist inside code, so require a plausible header."""
    out, i = [], 0
    while True:
        j = data.find(b"_FVH", i)
        if j < 0:
            return out
        base = j - 0x28
        if base >= 0:
            length = struct.unpack_from("<Q", data, base + 0x20)[0]
            hdrlen = struct.unpack_from("<H", data, base + 0x30)[0]
            if 0x48 <= hdrlen <= 0x400 and 0x1000 < length <= len(data) - base:
                out.append((base, length, hdrlen))
                i = base + length
                continue
        i = j + 1


class File:
    __slots__ = ("guid", "type", "attrs", "size", "state", "off", "hdr", "end", "raw", "fvbase")


def parse_file(d, off, end):
    if off + FFS_HDR > end or d[off] == 0xFF:
        return None
    f = File()
    f.guid = guid(d[off:off + 16])
    f.type = d[off + 0x12]
    f.attrs = d[off + 0x13]
    size = int.from_bytes(d[off + 0x14:off + 0x17], "little")
    f.state = d[off + 0x17]
    hdr = FFS_HDR
    if f.attrs & 0x01:  # EFI_FILE_DATA_ALIGNMENT / large file
        if off + 32 > end:
            return None
        size = struct.unpack_from("<Q", d, off + 0x18)[0]
        hdr = 32
    if f.type not in VALID_TYPES or size < hdr or off + size > end:
        return None
    f.size, f.off, f.hdr, f.end = size, off, hdr, off + size
    f.raw = d[off + hdr:f.end]
    f.fvbase = None
    return f


def walk(d, start, end):
    out, p = [], start
    while p + FFS_HDR <= end:
        if d[p] == 0xFF:
            n = p
            while n < end and d[n] == 0xFF:
                n += 1
            if n + FFS_HDR > end:
                break
            p = align4(n)
            continue
        f = parse_file(d, p, end)
        if not f:
            break
        out.append(f)
        p = align4(f.end)
    return out


def files_of(d, base, length, hdrlen):
    """Longest valid chain wins; the header length field lies in these images."""
    end, best, start = base + length, [], None
    for cand in range(hdrlen, min(hdrlen + 0x140, length)):
        got = walk(d, base + cand, end)
        if len(got) > len(best):
            best, start = got, cand
    return best, start


def sections(data):
    out, p, end = [], 0, len(data)
    while p + 4 <= end:
        size = int.from_bytes(data[p:p + 3], "little")
        typ = data[p + 3]
        hdr = 4
        if size == 0xFFFFFF:
            if p + 8 > end:
                break
            size = struct.unpack_from("<I", data, p + 4)[0]
            hdr = 8
        if size < hdr or p + size > end:
            break
        g = None
        if typ in GUIDED_TYPES:
            if p + hdr + 16 > end:
                break
            g = guid(data[p + hdr:p + hdr + 16])
            hdr += 16
        out.append((typ, g, data[p + hdr:p + size]))
        p += size if typ in GUIDED_TYPES else align4(size)
    return out


def lzma_try(blob):
    for fmt in (lzma.FORMAT_ALONE, lzma.FORMAT_AUTO):
        try:
            return lzma.decompress(blob, format=fmt)
        except Exception:
            pass
    return None


def decompress(typ, g, data):
    if typ == 0x02 and g == LZMA_GUID:
        # GUIDed header: DataOffset u16, Attributes u16 (offsets from section start;
        # the GUID is already stripped, hence the -0x14).
        if len(data) < 4:
            return None
        doff, attrs = struct.unpack_from("<HH", data, 0)
        if not (0x14 <= doff <= 0x14 + len(data)):
            return None
        body = data[doff - 0x14:]
        return lzma_try(body) if attrs & 0x01 else body
    if typ == 0x01:
        unc, ctyp = struct.unpack_from("<IB", data, 0)
        return data[5:5 + unc] if ctyp == 0 else None
    return None


# ---------------------------------------------------------------------- strings

def strings(data, minlen=5):
    """Yield (offset, text, wide) for ASCII and UTF-16LE runs."""
    cur, start = bytearray(), 0
    for i, b in enumerate(data):
        if 0x20 <= b < 0x7F:
            if not cur:
                start = i
            cur.append(b)
        else:
            if len(cur) >= minlen:
                yield start, cur.decode("ascii"), False
            cur = bytearray()
    if len(cur) >= minlen:
        yield start, cur.decode("ascii"), False

    cur, start, i = bytearray(), 0, 0
    while i + 1 < len(data):
        b = data[i]
        if 0x20 <= b < 0x7F and data[i + 1] == 0:
            if not cur:
                start = i
            cur.append(b)
            i += 2
        else:
            if len(cur) >= minlen:
                yield start, cur.decode("ascii"), True
            cur = bytearray()
            i += 1
    if len(cur) >= minlen:
        yield start, cur.decode("ascii"), True


def ui_name(f, minlen=3):
    for typ, g, data in sections(f.raw):
        if typ == 0x15:
            for off, s, wide in strings(data, minlen):
                if wide:
                    return s
    return ""


# ------------------------------------------------------------------- subcommands

def cmd_list(rom_path, only_named=False):
    rom = open(rom_path, "rb").read()

    def show(d, base, length, hdrlen, depth):
        fl, start = files_of(d, base, length, hdrlen)
        pad = "  " * depth
        print(f"{pad}FV @ {base:#09x} len {length:#09x} hdrlen {hdrlen:#x} "
              f"ffs@{start and hex(start)} files {len(fl)}")
        for f in fl:
            name = ui_name(f)
            if not only_named or name:
                print(f"{pad}  {f.off:08x} {f.type:02x} {TYPE_NAMES.get(f.type,'?'):19} "
                      f"{f.size:8d} {f.guid} {name}")
            if f.type != 0x0B:
                continue
            # container file: descend into FV images, compressed or not
            for typ, g, data in sections(f.raw):
                blobs = [data]
                if typ in (0x01, 0x02):
                    dec = decompress(typ, g, data)
                    blobs.append(dec)
                for blob in blobs:
                    if not blob:
                        continue
                    for b2, l2, h2 in find_fvs(blob):
                        show(blob, b2, l2, h2, depth + 1)
                        break

    for base, length, hdrlen in find_fvs(rom):
        show(rom, base, length, hdrlen, 0)


def cmd_extract(rom_path, outdir):
    rom = open(rom_path, "rb").read()

    def emit(path, data, meta):
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "data.bin"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(path, "meta.txt"), "w") as fh:
            fh.write(meta)

    def recurse(d, base, length, hdrlen, depth, tag):
        fl, start = files_of(d, base, length, hdrlen)
        for f in fl:
            name = ui_name(f) or f.guid
            safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in name)[:80]
            path = os.path.join(outdir, f"d{depth}_{tag}_{f.off:06x}_{f.type:02x}_{safe}")
            emit(path, f.raw, f"guid={f.guid}\ntype={f.type:#x}\nsize={f.size}\n"
                              f"fv={base:#x}\noff={f.off:#x}\nui={name}\n")
            for i, (typ, g, data) in enumerate(sections(f.raw)):
                sub = os.path.join(path, f"sec{i:02d}_{typ:02x}_{(g or 'none')[:8]}")
                emit(sub, data, f"type={typ:#x} ({SECTION_NAMES.get(typ,'?')})\nguid={g}\nsize={len(data)}\n")
                if typ in (0x17, 0x19) or typ in (0x01, 0x02):
                    for blob in (data, decompress(typ, g, data)) if typ in (0x01, 0x02) else (data,):
                        if not blob:
                            continue
                        for b2, l2, h2 in find_fvs(blob):
                            recurse(blob, b2, l2, h2, depth + 1, tag)
                            break

    for base, length, hdrlen in find_fvs(rom):
        recurse(rom, base, length, hdrlen, 0, f"{base:06x}")
    print(f"wrote {outdir}")


def grep_offsets(data, pattern, minlen=5):
    """Return (offset, text, wide) hits for pattern as ASCII and as UTF-16LE."""
    out = []
    for needle, wide, width in ((pattern.encode(), False, 1), (pattern.encode("utf-16-le"), True, 2)):
        i = 0
        while True:
            j = data.find(needle, i)
            if j < 0:
                break
            out.append((j, wide))
            i = j + 1
    return sorted(out)


def cmd_grep(rom_path, pattern):
    rom = open(rom_path, "rb").read()
    hits = grep_offsets(rom, pattern)
    for j, wide in hits:
        if wide:
            print(f"{j:08x}  w  {rom[max(0,j-40):j+80].decode('utf-16-le', 'ignore')[:70]!r}")
        else:
            print(f"{j:08x}  {rom[max(0,j-40):j+60].split(b'\0')[0][-90:].decode('latin1')!r}")
    if not hits:
        print("no match")


def nvar_records(data):
    """Yield (offset, name, payload) from an AMI 'NVAR' store. The record length is
    not stored in a field we can trust, so the payload runs to the next signature."""
    offs, i = [], 0
    while True:
        j = data.find(b"NVAR", i)
        if j < 0:
            break
        offs.append(j)
        i = j + 4
    for n, off in enumerate(offs):
        end = offs[n + 1] if n + 1 < len(offs) else len(data)
        name_end = data.find(b"\x00", off + 11, end)
        if name_end < 0:
            continue
        name = data[off + 11:name_end].decode("latin1", "replace")
        if not name.isprintable():
            continue
        yield off, name, data[name_end + 1:end]


def cmd_vars(rom_path):
    """Walk the NVRAM store. Layout is undocumented; treat names and values as
    hints and verify on the host before editing anything."""
    rom = open(rom_path, "rb").read()
    base, length, hdrlen = find_fvs(rom)[0]
    fl, start = files_of(rom, base, length, hdrlen)
    for f in fl:
        if f.type != 0x01:
            continue
        for off, name, data in nvar_records(f.raw):
            print(f"  {off:06x} {name:<28} {len(data):6d} {data[:24].hex()}"
                  f"{'...' if len(data) > 24 else ''}")


def diff_pages(a, b):
    """Offsets of differing 4 KiB pages; empty when equal."""
    if len(a) != len(b):
        raise ValueError("size mismatch")
    return [i for i in range(0, len(a), 4096) if a[i:i + 4096] != b[i:i + 4096]]


def cmd_diff(rom_a, rom_b):
    a, b = open(rom_a, "rb").read(), open(rom_b, "rb").read()
    try:
        pages = diff_pages(a, b)
    except ValueError:
        print("size mismatch")
        return 1
    runs = []
    for p in pages:
        if runs and p == runs[-1][1] + 4096:
            runs[-1][1] = p
        else:
            runs.append([p, p])
    print(f"{len(pages)} differing 4K pages")
    for s, e in runs:
        print(f"  {s:#08x}-{e + 0xfff:#08x}  {(e - s) // 4096 + 1:4d} pages")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, rest = argv[1], argv[2:]
    if cmd == "list" and rest:
        cmd_list(rest[0], "--named" in rest)
    elif cmd == "extract" and len(rest) == 2:
        cmd_extract(rest[0], rest[1])
    elif cmd == "grep" and len(rest) == 2:
        cmd_grep(rest[0], rest[1])
    elif cmd == "vars" and rest:
        cmd_vars(rest[0])
    elif cmd == "diff" and len(rest) == 2:
        cmd_diff(rest[0], rest[1])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main(sys.argv))
