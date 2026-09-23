#!/usr/bin/env python3
"""Generate the Mega System 1-Z .mra files from ONE table (tools/ms1z_romdata.py).

    tools/gen_ms1z_mra.py            write releases/*.mra
    tools/gen_ms1z_mra.py --check    off-board load model: build each set's
                                     index-0 stream from the zips, write nothing
    tools/gen_ms1z_mra.py --ioctl SET   write that stream for the hw sim

Derived from Arcade-JalecoMS1BCD_MiSTer's tools/gen_ms1bcd_mra.py; the XML
escaping, the FAT-safe file names, the parenthesis-free _alternatives
directory, the carried-over hiscore/cheat blocks and the map="01" = EVEN byte
rule (measured on the board, MS1BCD 2026-09-22) are that file's.

The DIP switches come from MAME's own -listxml, which resolves PORT_INCLUDE
and marks the defaults; this board has ONE 16-bit DSW port, so bits 0-15 map
straight onto the first two <switches> bytes.
"""
import argparse, os, re, subprocess, sys, zipfile, zlib
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape as _xml_escape

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ms1z_romdata as R

ROOT = os.path.join(HERE, '..')
ROMS = os.path.join(ROOT, 'mame_roms')
RELEASES = os.path.join(ROOT, 'releases')
MAME = os.path.expanduser('~/mame/mame')

def x(v):  return _xml_escape(str(v))
def xc(t):
    t = str(t).replace('--', '—')
    return t + ' ' if t.endswith('-') else t

FAT_FORBIDDEN = {':': '-', '/': '-', '\\': '-', '?': '', '*': '',
                 '<': '', '>': '', '|': '-', '"': "'"}
def fat_safe(desc):
    return ''.join(FAT_FORBIDDEN.get(c, c) for c in desc).rstrip('. ')
def alt_dir_name(desc):
    return fat_safe(desc.split(' (', 1)[0].rstrip())

# ------------------------------------------------------------------- DIPs
_COIN = re.compile(r'^(\d+) Coins?/(\d+) Credits?$')
def dip_id(name):
    if name == 'Free Play': return 'Free_Play'
    m = _COIN.match(name)
    return f'{m.group(1)}C_{m.group(2)}C' if m else name

def dips_from_mame(setname):
    xml = subprocess.run([MAME, '-listxml', setname], capture_output=True, text=True).stdout
    root = ET.fromstring(xml)
    mach = next(m for m in root.iter('machine') if m.get('name') == setname)
    default, dips = 0xFFFF, []
    for sw in mach.iter('dipswitch'):
        mask = int(sw.get('mask'))
        lo = (mask & -mask).bit_length() - 1
        hi = mask.bit_length() - 1
        width = hi - lo + 1
        if mask != ((1 << width) - 1) << lo:
            raise SystemExit(f'{setname}: {sw.get("name")} mask {mask:#x} is not contiguous')
        ids = ['Undefined'] * (1 << width)
        for v in sw.iter('dipvalue'):
            raw = int(v.get('value')) >> lo
            ids[raw] = v.get('name')
            if v.get('default') == 'yes':
                default = (default & ~mask) | int(v.get('value'))
        # Coin A/B: MAME omits duplicate settings; this port's 3-bit fields
        # have none, so any "Undefined" left here is a real gap -- say so.
        if 'Undefined' in ids:
            print(f'  note: {setname} {sw.get("name")} has undefined values', file=sys.stderr)
        dips.append(dict(name=sw.get('name'), bits=(lo, hi), ids=ids))
    return default, dips

def switches_xml(setname, flags):
    default, dips = dips_from_mame(setname)
    out = [f'  <switches default="{default & 0xFF:02X},{default >> 8:02X},{flags:02X}">\n']
    for d in dips:
        if d['name'] == 'Unused':
            continue
        lo, hi = d['bits']
        bits = f'{lo}' if lo == hi else f'{lo},{hi}'
        out.append(f'    <dip bits="{bits}" name="{x(d["name"])}" ids="{",".join(x(dip_id(i)) for i in d["ids"])}"/>\n')
    out.append('  </switches>\n')
    return ''.join(out)

# ------------------------------------------------------------------- parts
def parts_xml(setname):
    s = R.SETS[setname]
    lay, total = R.layout()
    out = []
    for region, base, size in lay:
        rsize, parts = s['regions'][region]
        out.append(f'    <!-- {region} 0x{size:06X} @ 0x{base:06X} -->\n')
        ev = [p for p in parts if p[3] == 'even']; od = [p for p in parts if p[3] == 'odd']
        if ev:
            # ROM_LOAD16_BYTE: the offset-0 chip is the 68000's HIGH byte, and
            # map="01" supplies the EVEN byte of the output word (MS1BCD,
            # measured on the board). So the even chip goes on map="01".
            out.append('    <interleave output="16">\n')
            out.append(f'      <part crc="{ev[0][1]:08x}" name="{x(ev[0][0])}" map="01"/>\n')
            out.append(f'      <part crc="{od[0][1]:08x}" name="{x(od[0][0])}" map="10"/>\n')
            out.append('    </interleave>\n')
        else:
            for fn, crc, sz, load in parts:
                out.append(f'    <part crc="{crc:08x}" name="{x(fn)}"/>\n')
    return ''.join(out)

def zip_attr(setname):
    return '|'.join(R.SETS[setname]['zips'])

BUTTONS = 'Button 1,Button 2,Button 3,Start,Coin'
BUTTON_DEFAULTS = 'Y,B,A,Start,R'

def mra(setname):
    s = R.SETS[setname]
    _, total = R.layout()
    proms = ''.join(f'    <part crc="{c:08x}" name="{x(n)}"/>\n' for n, c, _, _ in R.PROMS)
    return f"""<!--
  {xc(s['desc'])} — Jaleco 1988, MAME jaleco/megasys1.cpp ({setname}).
  Mega System 1 type Z. Generated by tools/gen_ms1z_mra.py from
  tools/ms1z_romdata.py; do not hand-edit.

  SDRAM image: 0x{total:06X} bytes. <switches> byte 2 is not a DIP: bit 7
  unlocks the Autofire menu (tools/gen_autofire_mra.py sets it in the
  autofire_releases/ copies), nothing else reads it.
-->
<misterromdescription>
  <name>{x(s['desc'])}</name>
  <mratimestamp>202609230000</mratimestamp>
  <mameversion>0289</mameversion>
  <setname>{setname}</setname>
  <year>1988</year>
  <manufacturer>Jaleco</manufacturer>
  <category>Arcade</category>
  <rbf>JalecoMS1Z</rbf>

{switches_xml(setname, 0x00)}
  <buttons names="{BUTTONS}" default="{BUTTON_DEFAULTS}"/>

  <rom index="0" zip="{zip_attr(setname)}" md5="none">
{parts_xml(setname)}  </rom>

  <!-- The board's two 256-byte PROMs (makaiden.9 / .10). MAME does not use
       them and they are not a priority PROM (docs/known-issues.md MS1Z-2);
       they ride along on their own index so the set is complete, and the
       core drops them. -->
  <rom index="1" zip="{zip_attr(setname)}" md5="none">
{proms}  </rom>
</misterromdescription>
"""

CARRY_RE = re.compile(r'\n  <!-- (?:High scores|Cheats).*?</rom>\n(?:  <nvram index="4"[^/]*/>\n)?', re.S)
def carry_over(path):
    if not os.path.exists(path): return ''
    return ''.join(CARRY_RE.findall(open(path, encoding='utf-8').read()))

def stream(setname):
    """The index-0 byte stream exactly as the core receives it."""
    parts = R.part_files(setname, ROMS)
    return b''.join(parts[r] for r, _, _ in R.layout()[0])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--ioctl', metavar='SET')
    a = ap.parse_args()
    if a.check:
        for sn in R.SETS:
            st = stream(sn)
            print(f'{sn:9s} stream 0x{len(st):06X}  crc32 {zlib.crc32(st):08x}  OK')
        return
    if a.ioctl:
        out = os.path.join(ROOT, 'sim', 'rtl', 'ms1z_hw', 'roms', a.ioctl + '_ioctl.bin')
        os.makedirs(os.path.dirname(out), exist_ok=True)
        open(out, 'wb').write(stream(a.ioctl))
        print('wrote', out); return
    for sn, s in R.SETS.items():
        if s['parent']:
            d = os.path.join(RELEASES, '_alternatives', '_' + alt_dir_name(R.SETS[s['parent']]['desc']))
        else:
            d = RELEASES
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, fat_safe(s['desc']) + '.mra')
        keep = carry_over(path)
        open(path, 'w', encoding='utf-8').write(
            mra(sn).replace('</misterromdescription>', keep + '</misterromdescription>'))
        print('wrote', os.path.relpath(path, ROOT), '(+ carried blocks)' if keep else '')

if __name__ == '__main__':
    main()
