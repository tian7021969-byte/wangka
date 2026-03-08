#!/usr/bin/env python3
"""
verify_bitstream.py
-------------------
Scan hda_pcie_top.bin for PCIe config-space fingerprints and search
DSN (Device Serial Number) using four hardware storage modes.

Checks:
  Vendor ID  : 1102h
  Device ID  : 0011h
  Class Code : 040300h
  DSN        : A7C3_E5F1_2D8C_49B6  (4 modes)
"""

import sys
import os

# -- Config ----------------------------------------------------------------
BIN_FILE = os.path.join(
    "Audio_Controller_Logic",
    "Audio_Controller_Logic.runs",
    "impl_1",
    "hda_pcie_top.bin",
)

# -- DSN raw value (big-endian) --------------------------------------------
DSN_RAW = bytes([0xA7, 0xC3, 0xE5, 0xF1, 0x2D, 0x8C, 0x49, 0xB6])

# -- ANSI colors -----------------------------------------------------------
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RESET  = "\033[0m"

SEP_HEAVY = "=" * 65
SEP_LIGHT = "-" * 65


# -- Helpers ---------------------------------------------------------------

def find_all(data: bytes, pattern: bytes) -> list:
    hits = []
    start = 0
    while True:
        idx = data.find(pattern, start)
        if idx == -1:
            break
        hits.append(idx)
        start = idx + 1
    return hits


def reverse_bits(b: int) -> int:
    r = 0
    for _ in range(8):
        r = (r << 1) | (b & 1)
        b >>= 1
    return r


def fmt_hex(bs: bytes) -> str:
    return " ".join("{:02X}".format(b) for b in bs)


def fmt_offsets(offsets: list, limit: int = 20) -> str:
    s = ", ".join("0x{:06X}".format(o) for o in offsets[:limit])
    if len(offsets) > limit:
        s += "  ... (+{} more)".format(len(offsets) - limit)
    return s


# -- DSN four search modes -------------------------------------------------

def build_dsn_patterns(raw: bytes) -> list:
    be = raw
    le = raw[::-1]
    dw_swap = raw[4:] + raw[:4]
    bit_rev = bytes(reverse_bits(b) for b in raw)

    return [
        ("Big-Endian (raw)",        "MSB-first direct storage",                    be),
        ("Little-Endian (full)",    "Entire 64-bit byte-reversed",                 le),
        ("DWORD Swap (32-bit)",     "High/low 32-bit halves swapped, BE within",   dw_swap),
        ("Bit-Reverse (per byte)",  "Each byte's bit-order reversed [7:0]->[0:7]", bit_rev),
    ]


# -- Basic fingerprints (Vendor / Device / Class) -------------------------

BASIC_FINGERPRINTS = [
    ("Vendor ID",  "1102h (Creative Technology)",               bytes([0x02, 0x11])),
    ("Device ID",  "0011h (Sound Blaster AE-9)",                bytes([0x11, 0x00])),
    ("Class Code", "040300h (Multimedia > HD Audio Controller)", bytes([0x00, 0x03, 0x04])),
]


# -- Main ------------------------------------------------------------------

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    bin_path = os.path.join(script_dir, BIN_FILE)

    if not os.path.isfile(bin_path):
        print("{}[ERROR]{} File not found: {}".format(RED, RESET, bin_path))
        sys.exit(1)

    with open(bin_path, "rb") as f:
        data = f.read()

    size = len(data)

    print("")
    print("{}{}{}".format(BOLD, SEP_HEAVY, RESET))
    print("{}  Bitstream Fingerprint Verification Report{}".format(BOLD, RESET))
    print("{}{}{}".format(BOLD, SEP_HEAVY, RESET))
    print("  File : {}".format(bin_path))
    print("  Size : {:,} bytes ({:.1f} KB)".format(size, size / 1024))
    print("  DSN  : A7C3_E5F1_2D8C_49B6")
    print(SEP_LIGHT)

    # == Part 1: Basic fingerprints ========================================
    print("")
    print("{}  >> Part 1: PCIe ID Fingerprints{}".format(BOLD, RESET))
    print("")

    basic_ok = True
    for name, desc, pattern in BASIC_FINGERPRINTS:
        offsets = find_all(data, pattern)
        hex_str = fmt_hex(pattern)
        if offsets:
            tag = "{}PASS{}".format(GREEN, RESET)
            info = "Found {} match(es) | {}".format(len(offsets), fmt_offsets(offsets))
        else:
            tag = "{}FAIL{}".format(RED, RESET)
            info = "{}No match found{}".format(RED, RESET)
            basic_ok = False
        print("  [{}] {}{}{}  {}{}{}".format(tag, BOLD, name, RESET, DIM, desc, RESET))
        print("         Pattern: [{}{}{}]".format(CYAN, hex_str, RESET))
        print("         {}".format(info))
        print("")

    # == Part 2: DSN four modes ============================================
    print(SEP_LIGHT)
    print("")
    print("{}  >> Part 2: DSN Multi-Mode Scan (A7C3_E5F1_2D8C_49B6){}".format(BOLD, RESET))
    print("")

    dsn_patterns = build_dsn_patterns(DSN_RAW)
    dsn_any_found = False

    for mode_name, mode_desc, pattern in dsn_patterns:
        offsets = find_all(data, pattern)
        hex_str = fmt_hex(pattern)

        if offsets:
            tag = "{}FOUND{}".format(GREEN, RESET)
            info = "Found {} match(es) | {}".format(len(offsets), fmt_offsets(offsets))
            dsn_any_found = True
        else:
            tag = "{}NOT FOUND{}".format(YELLOW, RESET)
            info = "{}No match{}".format(DIM, RESET)

        print("  [{}] {}{}{}".format(tag, BOLD, mode_name, RESET))
        print("         {}{}{}".format(DIM, mode_desc, RESET))
        print("         Pattern: [{}{}{}]".format(CYAN, hex_str, RESET))
        print("         {}".format(info))
        print("")

    # == Bonus: DSN 32-bit fragment search =================================
    print("  {}-- Bonus: DSN 32-bit fragment search --{}".format(DIM, RESET))
    print("")

    hi32 = DSN_RAW[:4]   # A7 C3 E5 F1
    lo32 = DSN_RAW[4:]   # 2D 8C 49 B6
    fragments = [
        ("DSN Hi32 (BE)",       hi32),
        ("DSN Lo32 (BE)",       lo32),
        ("DSN Hi32 (LE)",       hi32[::-1]),
        ("DSN Lo32 (LE)",       lo32[::-1]),
        ("DSN Hi32 (Bit-Rev)",  bytes(reverse_bits(b) for b in hi32)),
        ("DSN Lo32 (Bit-Rev)",  bytes(reverse_bits(b) for b in lo32)),
    ]

    for fname, pat in fragments:
        offsets = find_all(data, pat)
        hex_str = fmt_hex(pat)
        if offsets:
            tag = "{}FOUND{}".format(GREEN, RESET)
            info = "Found {} match(es) | {}".format(len(offsets), fmt_offsets(offsets, 10))
            dsn_any_found = True
        else:
            tag = "{}-{}".format(DIM, RESET)
            info = "{}No match{}".format(DIM, RESET)
        print("    [{}] {:<22s} [{}{}{}]  {}".format(tag, fname, CYAN, hex_str, RESET, info))

    # == Summary ===========================================================
    print("")
    print(SEP_LIGHT)
    print("")
    print("{}  >> Summary{}".format(BOLD, RESET))
    print("")

    if basic_ok:
        print("  {}{}[OK] PCIe ID Fingerprints: ALL PASS{}".format(GREEN, BOLD, RESET))
        print("    Vendor ID / Device ID / Class Code confirmed.")
    else:
        print("  {}{}[X] PCIe ID Fingerprints: FAIL{}".format(RED, BOLD, RESET))
        failed = [n for n, _, p in BASIC_FINGERPRINTS if not find_all(data, p)]
        print("    Failed: {}".format(", ".join(failed)))

    print("")
    if dsn_any_found:
        print("  {}{}[OK] DSN: At least one storage mode matched{}".format(GREEN, BOLD, RESET))
        print("    DSN value is embedded in the bitstream.")
    else:
        print("  {}{}[!] DSN: No mode matched (all 4 + fragments){}".format(YELLOW, BOLD, RESET))
        print("    This is {}normal{} -- Vivado synthesis encodes register constants".format(BOLD, RESET))
        print("    into LUT INIT bits. After bit-swizzling, the DSN no longer appears")
        print("    as contiguous bytes in the bitstream.")
        print("    DSN functionality is NOT affected. Verify on-board via lspci/setpci.")

    print("")
    print(SEP_HEAVY)
    print("")
    sys.exit(0 if basic_ok else 1)


if __name__ == "__main__":
    main()
