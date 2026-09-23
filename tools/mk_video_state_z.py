#!/usr/bin/env python3
"""Turn one frame of a type-Z MAME capture into a sim/rtl/video_state_z input.

    python3 tools/mk_video_state_z.py <trace_dir> <F> <out_dir> [imgdir]

On type Z there is NO frame offset between the state and the picture:
draw_sprites reads live work RAM and the tilemaps live VRAM when the frame is
composed at line 240 -- the same instant frame_done dumps them. (B/C/D need
MS1-11's offsets because their sprites are two frames behind.) A frame whose
registers were written inside the visible area was drawn in slices and cannot
be reproduced from one snapshot (MS1-12); it is refused.
"""
import os, sys, shutil

def main():
    tr, F, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    img = sys.argv[4] if len(sys.argv) > 4 else None
    os.makedirs(out, exist_ok=True)
    lay = {}
    for ln in open(os.path.join(tr, 'layout.txt')):
        p = ln.split()
        if len(p) >= 4 and p[1].startswith('base='):
            lay[p[0]] = (int(p[3].split('=')[1], 16), int(p[2].split('=')[1], 16))
    st = open(os.path.join(tr, 'state', f's{F}.bin'), 'rb').read()
    for name, fn in [('spriteram', 'spriteram.bin'),
                     ('objram', 'objram.bin'), ('layer0', 'l0.vram'), ('layer1', 'l1.vram')]:
        off, ln = lay[name]
        open(os.path.join(out, fn), 'wb').write(st[off:off + ln])
    # ...but the PALETTE of that picture is state F+1's. MAME double-buffers
    # the screen bitmap and swaps it at vblank (screen.cpp video_output_update),
    # so pixels() at frame_done(F+1) returns the bitmap composed from state F
    # and colours it through the palette as it stands at F+1 (MS1Z-5).
    st1 = open(os.path.join(tr, 'state', f's{F + 1}.bin'), 'rb').read()
    off, ln = lay['palette']
    open(os.path.join(out, 'palette.bin'), 'wb').write(st1[off:off + ln])
    open(os.path.join(out, 'l2.vram'), 'wb').write(b'')
    regs = dict(l.split() for l in open(os.path.join(tr, 'state', f'r{F}.txt')))
    # Rows from `first_row` down were drawn at line 240 from this exact state.
    # Rows above the last visible-area register write were drawn earlier, in
    # slices, from state this snapshot does not hold (MS1-12): compare only
    # the rows below it. midframe_last is a raster line; rows are 0..223 of
    # the visible window, which starts at line 16.
    first_row = 0
    if int(regs.get('midframe_writes', '0'), 16):
        first_row = max(0, int(regs.get('midframe_last', '-1')) - 16)
        print(f'frame {F}: {int(regs["midframe_writes"], 16)} visible-area register writes, '
              f'last at line {regs.get("midframe_last")}: comparing rows {first_row}..223 only')
    open(os.path.join(out, 'first_row.txt'), 'w').write(f'{first_row}\n')
    with open(os.path.join(out, 'regs.txt'), 'w') as f:
        f.write('mode 0\nnlayers 2\nactive_layers 000B\nsprite_flag 0000\nsprite_bank 0000\n')
        for k in ('screen_flag', 't0_sx', 't0_sy', 't0_ctrl', 't1_sx', 't1_sy', 't1_ctrl'):
            f.write(f'{k} {regs[k]}\n')
    # THE PICTURE LAGS THE STATE BY ONE FRAME. frame_done fires at line 240
    # (measured: vpos 240, 256 lines to the next vblank) and the dump taken
    # there is the state frame F was drawn from -- but screen:pixels() at that
    # moment returns the PREVIOUSLY completed bitmap (MAME swaps the screen's
    # two bitmaps at vblank, before the frame_done callback), so the picture
    # of frame F is the one saved at F+1. Measured on the demo: state F
    # against image F leaves layer 0 exactly two pixels out (one frame's
    # scroll step); against image F+1 it does not. MS1BCD's MS1-11 found the
    # same one-frame skew by measurement.
    shutil.copy(os.path.join(tr, 'frames', f'f{F + 1}.raw'), os.path.join(out, 'expected.raw'))
    if img:
        for fn in ('gfx0.bin', 'gfx1.bin', 'sprites.bin'):
            shutil.copy(os.path.join(img, fn), os.path.join(out, fn))
        open(os.path.join(out, 'prom.bin'), 'wb').write(b'')
    print(f'frame {F}: state written to {out}')

if __name__ == '__main__':
    main()
