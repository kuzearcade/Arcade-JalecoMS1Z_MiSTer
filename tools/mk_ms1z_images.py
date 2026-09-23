#!/usr/bin/env python3
"""Build the per-region ROM images the simulation harnesses read, straight
from the user's MAME zips (never committed: see .gitignore, **/roms/*.bin).

    python3 tools/mk_ms1z_images.py <set> <outdir>
        set: lomakai | makaiden

Writes maincpu.bin (the 68000 pair interleaved, even byte first -- the order
the harness builds words in, (image[even] << 8) | image[odd]), audiocpu.bin,
gfx0.bin (scroll1 -> layer 0), gfx1.bin (scroll2 -> layer 1), sprites.bin and
prom.bin. Every part is checked against MAME's CRC first (megasys1.cpp:3966).
"""
import os, sys, zipfile, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
from ms1z_romdata import SETS, part_files

def main():
    name, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    files = part_files(name, os.path.join(ROOT, 'mame_roms'))
    for region, data in files.items():
        open(os.path.join(out, region + '.bin'), 'wb').write(data)
        print(f'{region:9s} {len(data):7d} bytes')

if __name__ == '__main__':
    main()
