"""The one table of Mega System 1-Z ROM data: MAME 0.289's ROM_START( lomakai )
and ROM_START( makaiden ) (megasys1.cpp:3966-4010). The .mra generator, the
simulation image builder and the SDRAM map generator all read THIS, so the
three cannot disagree (MS1BCD docs/PLAN.md 1.5).

Region order is the SDRAM order of the ioctl index-0 stream; ms1z_rom_map.vh
is generated from it by tools/gen_rom_map.py.
"""
import os, zipfile, zlib

# region -> (size, [ (file, crc, size, load) ... ]) with load in
#   'even' / 'odd'  : ROM_LOAD16_BYTE into a 16-bit region
#   int             : plain ROM_LOAD at that offset
LOMAKAI = {
    'maincpu':  (0x40000, [('lom_30.rom', 0xba6d65b8, 0x20000, 'even'),
                           ('lom_20.rom', 0x56a00dc2, 0x20000, 'odd')]),
    'audiocpu': (0x10000, [('lom_01.rom', 0x46e85e90, 0x10000, 0)]),
    'gfx0':     (0x20000, [('lom_05.rom', 0xd04fc713, 0x20000, 0)]),   # scroll1
    'gfx1':     (0x10000, [('lom_08.rom', 0xbdb15e67, 0x10000, 0)]),   # scroll2
    'sprites':  (0x20000, [('lom_06.rom', 0xf33b6eed, 0x20000, 0)]),
}
PROMS = [('makaiden.9', 0x3567065d, 0x100, 0), ('makaiden.10', 0xe6709c51, 0x100, 0x100)]

MAKAIDEN = dict(LOMAKAI)
MAKAIDEN['maincpu'] = (0x40000, [('makaiden.3a', 0x87cf81d1, 0x20000, 'even'),
                                 ('makaiden.2a', 0xd40e0fea, 0x20000, 'odd')])
MAKAIDEN['gfx1'] = (0x10000, [('makaiden.8', 0xa7f623f9, 0x10000, 0)])

SETS = {
    'lomakai':  dict(desc='Legend of Makai (World)', parent=None,
                     zips=['lomakai.zip'], regions=LOMAKAI),
    'makaiden': dict(desc='Makai Densetsu (Japan)', parent='lomakai',
                     zips=['makaiden.zip', 'lomakai.zip'], regions=MAKAIDEN),
}
REGION_ORDER = ['maincpu', 'audiocpu', 'gfx0', 'gfx1', 'sprites']


def _read(name, zips, romdir):
    for z in zips:
        p = os.path.join(romdir, z)
        if not os.path.exists(p):
            continue
        with zipfile.ZipFile(p) as zf:
            if name in zf.namelist():
                return zf.read(name)
    raise SystemExit(f'{name}: not found in {zips} under {romdir}')


def part_files(setname, romdir):
    """{region: bytes} for every region plus 'prom', CRC-checked."""
    s = SETS[setname]
    out = {}
    for region in REGION_ORDER + ['prom']:
        size, parts = (0x200, PROMS) if region == 'prom' else s['regions'][region]
        buf = bytearray(b'\xff' * size)
        for fn, crc, sz, load in parts:
            d = _read(fn, s['zips'], romdir)
            if len(d) != sz or (zlib.crc32(d) & 0xffffffff) != crc:
                raise SystemExit(f'{fn}: size {len(d)} crc {zlib.crc32(d):08x}, '
                                 f'MAME wants {sz} {crc:08x}')
            if load == 'even':
                buf[0::2] = d
            elif load == 'odd':
                buf[1::2] = d
            else:
                buf[load:load + sz] = d
        out[region] = bytes(buf)
    return out


def layout():
    """[(region, byte base, size)] in SDRAM order."""
    base, out = 0, []
    for r in REGION_ORDER:
        size = LOMAKAI[r][0]
        out.append((r, base, size))
        base += size
    return out, base
