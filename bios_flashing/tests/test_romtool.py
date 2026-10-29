"""Tests for romtool.py. Standard library only: `uv run python -m unittest discover -s tests`.

The images are not distributed (*.rom is git-ignored), so anything that needs one
skips when it is absent.
"""

import contextlib
import io
import os
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

import romtool as R  # noqa: E402

P2 = os.path.join(HERE, "bios-backup-1.rom")
P3 = os.path.join(HERE, "BC250_3.00_CHIPSETMENU.ROM")
READBACK = os.path.join(HERE, "readback.rom")

def have(*paths):
    return all(os.path.exists(p) for p in paths)

def load(path):
    with open(path, "rb") as fh:
        return fh.read()


class TestVolumeParse(unittest.TestCase):
    @unittest.skipUnless(have(READBACK), "no dump")
    def test_three_volumes_at_known_offsets(self):
        rom = load(READBACK)
        fvs = R.find_fvs(rom)
        self.assertEqual([f[0] for f in fvs], [0x0, 0xAE0000, 0xE00000])
        self.assertEqual([f[1] for f in fvs], [0x20000, 0x320000, 0x200000])

    def test_random_data_has_no_volume(self):
        self.assertEqual(R.find_fvs(bytes(0x40000)), [])

    @unittest.skipUnless(have(READBACK), "no dump")
    def test_ffs_area_is_not_at_stored_header_length(self):
        # The stored HeaderLength is 0x48; files start at 0x78. Guard both, so a
        # future image that fixes the header is noticed rather than silently parsed.
        rom = load(READBACK)
        base, length, hdrlen = R.find_fvs(rom)[0]
        self.assertEqual(hdrlen, 0x48)
        fl, start = R.files_of(rom, base, length, hdrlen)
        self.assertEqual(start, 0x74)  # >= hdrlen, first file at 0x78 after FF padding
        self.assertEqual(len(fl), 1)

    def test_parse_file_rejects_garbage(self):
        self.assertIsNone(R.parse_file(b"\xff" * 64, 0, 64))
        self.assertIsNone(R.parse_file(bytes(64), 0, 64))

    def test_walk_on_erased_region_is_empty(self):
        self.assertEqual(R.walk(b"\xff" * 0x2000, 0, 0x2000), [])


class TestContainer(unittest.TestCase):
    @unittest.skipUnless(have(READBACK), "no dump")
    def test_dxe_volume_is_one_lzma_container(self):
        rom = load(READBACK)
        base, length, hdrlen = R.find_fvs(rom)[1]
        fl, _ = R.files_of(rom, base, length, hdrlen)
        self.assertEqual(len(fl), 1)
        f = fl[0]
        self.assertEqual(f.type, 0x0B)
        self.assertEqual(f.size, 1314371)
        secs = R.sections(f.raw)
        self.assertEqual(len(secs), 1)
        typ, guid, payload = secs[0]
        self.assertEqual(typ, 0x02)
        self.assertEqual(guid, R.LZMA_GUID)

    @unittest.skipUnless(have(READBACK), "no dump")
    def test_decompressed_volume_holds_the_drivers(self):
        rom = load(READBACK)
        base, length, hdrlen = R.find_fvs(rom)[1]
        f = R.files_of(rom, base, length, hdrlen)[0][0]
        typ, guid, payload = R.sections(f.raw)[0]
        dec = R.decompress(typ, guid, payload)
        self.assertIsNotNone(dec)
        self.assertEqual(len(dec), 4292624)
        b2, l2, h2 = R.find_fvs(dec)[0]
        self.assertEqual(l2, 0x418000)
        fl, _ = R.files_of(dec, b2, l2, h2)
        self.assertEqual(len(fl), 186)
        names = {R.ui_name(x) for x in fl}
        self.assertIn("Setup", names)
        self.assertIn("CbsSetupDxe", names)

    def test_decompress_of_garbage_is_none(self):
        self.assertIsNone(R.decompress(0x02, R.LZMA_GUID, b"\x00" * 32))
        self.assertIsNone(R.decompress(0x02, R.LZMA_GUID, b"\x18\x00\x01\x00" + b"\x00" * 32))
        self.assertIsNone(R.decompress(0x02, "not-the-lzma-guid", b"\x18\x00\x01\x00"))

    def test_uncompressed_section_passes_through(self):
        sec = struct.pack("<IB", 4, 0) + b"abcd"
        self.assertEqual(R.decompress(0x01, None, sec), b"abcd")


class TestStrings(unittest.TestCase):
    def test_ascii_and_wide(self):
        data = b"xxDATAxx\x00" + "WIDE".encode("utf-16-le") + b"\x00\x00yy"
        hits = list(R.strings(data, 4))
        self.assertTrue(any("DATA" in s for _, s, w in hits if not w))
        self.assertTrue(any("WIDE" in s for _, s, w in hits if w))

    def test_minlen(self):
        self.assertEqual([s for _, s, _ in R.strings(b"ab\0cdef\0", 4)], ["cdef"])

    @unittest.skipUnless(have(READBACK), "no dump")
    def test_cbs_power_options_present(self):
        rom = load(READBACK)
        base, length, hdrlen = R.find_fvs(rom)[1]
        f = R.files_of(rom, base, length, hdrlen)[0][0]
        typ, guid, payload = R.sections(f.raw)[0]
        dec = R.decompress(typ, guid, payload)
        b2, l2, h2 = R.find_fvs(dec)[0]
        fl, _ = R.files_of(dec, b2, l2, h2)
        cbs = [x for x in fl if R.ui_name(x) == "CbsSetupDxe"]
        self.assertEqual(len(cbs), 1)
        text = "\n".join(s for _, s, w in R.strings(cbs[0].raw, 4) if w)
        for opt in ("Memory Clock Speed", "Power Down Enable", "DF Cstate",
                    "Link ASPM", "FAST_PPT_LIMIT", "SMU Features"):
            self.assertIn(opt, text)


class TestNvram(unittest.TestCase):
    @unittest.skipUnless(have(READBACK), "no dump")
    def test_setup_variables_are_findable(self):
        rom = load(READBACK)
        base, length, hdrlen = R.find_fvs(rom)[0]
        fl, _ = R.files_of(rom, base, length, hdrlen)
        store = [f for f in fl if f.type == 0x01]
        self.assertEqual(len(store), 1)
        recs = {name: payload for _, name, payload in R.nvar_records(store[0].raw)}
        self.assertIn("Setup", recs)
        self.assertIn("AmdSetup", recs)
        self.assertGreater(len(recs["Setup"]), 100)
        self.assertGreater(len(recs["AmdSetup"]), 1000)

    def test_nvar_on_empty_store(self):
        self.assertEqual(list(R.nvar_records(b"\xff" * 512)), [])


class TestGrep(unittest.TestCase):
    @unittest.skipUnless(have(READBACK), "no dump")
    def test_raw_rom_grep_finds_smu_blob_magic(self):
        rom = load(READBACK)
        hits = [off for off, wide in R.grep_offsets(rom, "$PS1") if not wide]
        self.assertIn(0x8FF010, hits)  # SMU blob entry header in both images
        self.assertEqual(rom[0x8FF000:0x8FF010],
                         bytes.fromhex("0e0a070ca7666c197a4d0ea8bea8da59"))

    @unittest.skipUnless(have(READBACK), "no dump")
    def test_cbs_text_only_appears_after_decompression(self):
        rom = load(READBACK)
        self.assertEqual([h for h in R.grep_offsets(rom, "Memory Clock Speed") if h[1]], [])
        base, length, hdrlen = R.find_fvs(rom)[1]
        f = R.files_of(rom, base, length, hdrlen)[0][0]
        dec = R.decompress(*R.sections(f.raw)[0])
        b2, l2, h2 = R.find_fvs(dec)[0]
        cbs = [x for x in R.files_of(dec, b2, l2, h2)[0] if R.ui_name(x) == "CbsSetupDxe"][0]
        self.assertTrue([h for h in R.grep_offsets(cbs.raw, "Memory Clock Speed") if h[1]])

    def test_no_match(self):
        self.assertEqual(R.grep_offsets(b"abc" * 100, "zzzz"), [])


class TestDiff(unittest.TestCase):
    @unittest.skipUnless(have(READBACK, P3), "no dump")
    def test_readback_matches_flashed_image(self):
        self.assertEqual(R.diff_pages(load(READBACK), load(P3)), [])

    @unittest.skipUnless(have(READBACK, P2), "no dump")
    def test_p2_versus_readback(self):
        pages = R.diff_pages(load(P2), load(READBACK))
        self.assertEqual(len(pages), 355)
        self.assertIn(0, pages)


class TestCli(unittest.TestCase):
    def run_cli(self, argv):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = R.main(argv)
        return rc, buf.getvalue()

    def test_no_args_prints_usage(self):
        rc, out = self.run_cli(["romtool.py"])
        self.assertEqual(rc, 2)
        self.assertIn("Subcommands", out)

    def test_unknown_command(self):
        self.assertEqual(self.run_cli(["romtool.py", "frobnicate"])[0], 2)

    def test_missing_operand(self):
        self.assertEqual(self.run_cli(["romtool.py", "extract", "x.rom"])[0], 2)


if __name__ == "__main__":
    unittest.main()
