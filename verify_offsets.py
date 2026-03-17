#!/usr/bin/env python3
"""
verify_offsets.py — sanity-check the ARM64 patch offsets for BlueStacks
Usage: python3 verify_offsets.py [path-to-BlueStacks-binary]
"""

import os
import sys

BINARY_DEFAULT = "/Applications/BlueStacks.app/Contents/MacOS/BlueStacks"

# ARM64 'ret' instruction (little-endian): D6 5F 03 C0 → bytes C0 03 5F D6
RET = b"\xc0\x03\x5f\xd6"

# Known ARM64 function prologues start with 'sub sp, sp, #N' or 'stp x29, x30, ...'
# We just verify they are NOT already 'ret' and look like real code.
PATCHES = {
    0x205BD0: "plrAdsInit",
    0x39F72C: "cldGetCpmStarAds",
    0x39F518: "cldGetCpiAds",
}

GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
RED = "\033[0;31m"
CYAN = "\033[0;36m"
RESET = "\033[0m"


def tag(color, text):
    return f"{color}{text}{RESET}"


def check(binary_path):
    if not os.path.isfile(binary_path):
        print(tag(RED, f"[ERROR] Binary not found: {binary_path}"))
        sys.exit(1)

    size = os.path.getsize(binary_path)
    print(f"\n{tag(CYAN, 'Binary:')} {binary_path}")
    print(f"{tag(CYAN, 'Size  :')} {size:,} bytes ({size / 1024 / 1024:.1f} MB)\n")

    if size < 1_000_000:
        print(tag(RED, "[ERROR] Binary looks too small — wrong file?"))
        sys.exit(1)

    all_ok = True

    with open(binary_path, "rb") as f:
        for offset, label in sorted(PATCHES.items()):
            if offset >= size:
                print(
                    tag(
                        RED,
                        f"  [FAIL]  0x{offset:07x}  {label:<22}  offset beyond file end!",
                    )
                )
                all_ok = False
                continue

            f.seek(offset)
            data = f.read(4)

            if len(data) < 4:
                print(
                    tag(
                        RED,
                        f"  [FAIL]  0x{offset:07x}  {label:<22}  could not read 4 bytes",
                    )
                )
                all_ok = False
                continue

            if data == RET:
                status = tag(YELLOW, "[already patched — ret]")
            elif data == b"\x00\x00\x00\x00":
                status = tag(RED, "[SUSPICIOUS — all zeros]")
                all_ok = False
            else:
                # Show the raw bytes so the user can cross-check with a disassembler
                status = tag(GREEN, f"[original code: {data.hex()}]")

            print(f"  0x{offset:07x}  {label:<22}  {status}")

    print()
    if all_ok:
        print(tag(GREEN, "[✓] All offsets look valid — safe to run bluestacks-noad.sh"))
    else:
        print(
            tag(
                RED,
                "[✗] One or more offsets are suspect — do NOT patch without verifying manually",
            )
        )
        sys.exit(1)

    print()
    print("Cross-check with:")
    print(
        f"  nm \"{binary_path}\" 2>/dev/null | grep -E 'plrAdsInit|cldGetCpmStar|cldGetCpi'"
    )
    print()
    print("Expected output (VA − 0x100000000 = file offset):")
    print("  0000000100205bd0 T __Z10plrAdsInit...")
    print("  000000010039f518 T __Z12cldGetCpiAds...")
    print("  000000010039f72c T __Z16cldGetCpmStarAds...")


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else BINARY_DEFAULT
    check(path)
