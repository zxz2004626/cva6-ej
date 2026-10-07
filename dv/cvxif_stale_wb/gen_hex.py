#!/usr/bin/env python3
"""Flat binary (objcopy -O binary) -> $readmemh 64-bit little-endian words.

The testbench maps physical address 0x8000_0000 to memory word 0, and the
program is linked at 0x8000_0000, so no base padding is needed.
"""
import sys, struct
bin_path, hex_path = sys.argv[1], sys.argv[2]
data = open(bin_path, "rb").read()
if len(data) % 8:
    data += b"\x00" * (8 - len(data) % 8)
words = struct.unpack("<%dQ" % (len(data) // 8), data)
open(hex_path, "w").write("\n".join("%016x" % w for w in words) + "\n")
print("wrote %s: %d words" % (hex_path, len(words)))
