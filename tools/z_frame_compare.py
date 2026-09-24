#!/usr/bin/env python3
"""Compare the core's frames against MAME's at a FIXED frame offset.

    python3 tools/z_frame_compare.py <core_dir> <mame_dir> [first last] [--kmin -30 --kmax 30]

core_dir: f<NNNNN>.raw from sim/rtl/ms1z_frames (MS1_FRAMEDIR), RGB, 256x224x3.
mame_dir: frames/f<N>.raw from sim/oracle/ms1_capture.lua, xRGB u32 LE.

The board and MAME do not leave reset on the same frame boundary, so the
comparison searches for the one offset k that aligns the runs best (core
frame i against MAME frame i+k), then reports -- at that k -- the frames
that are pixel-exact, the longest contiguous exact run, and the non-blank
pixel count beside every match (MS1BCD's M2 gate 2 format: a match of two
black frames proves nothing).
"""
import argparse, os, sys
import numpy as np

W, H = 256, 224

def load_idx(d, i):
    p = os.path.join(d, 'i%05d.raw' % i)
    if not os.path.exists(p): return None
    return np.frombuffer(open(p, 'rb').read(), '<u2').reshape(H, W)

def mame_palette(d, F):
    """Palette RGB (1024 x 3) from a MAME state dump, RRRRGGGGBBBBRGBx."""
    p = os.path.join(d, 'state', 's%d.bin' % F)
    if not os.path.exists(p): return None
    w = np.frombuffer(open(p, 'rb').read()[:0x800], '<u2').astype(np.int32)
    p5 = lambda v: (v << 3) | (v >> 2)
    r = p5(((w >> 12) & 0xF) << 1 | ((w >> 3) & 1))
    g = p5(((w >> 8) & 0xF) << 1 | ((w >> 2) & 1))
    b = p5(((w >> 4) & 0xF) << 1 | ((w >> 1) & 1))
    return np.stack([r, g, b], 1).astype(np.uint8)

def load_core(d, i):
    p = os.path.join(d, 'f%05d.raw' % i)
    if not os.path.exists(p): return None
    return np.frombuffer(open(p, 'rb').read(), np.uint8).reshape(H, W, 3)

def load_mame(d, i):
    p = os.path.join(d, 'frames', 'f%d.raw' % i)
    if not os.path.exists(p): return None
    a = np.frombuffer(open(p, 'rb').read(), np.uint8).reshape(H, W, 4)
    return a[:, :, [2, 1, 0]]          # B G R A -> R G B

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('core'); ap.add_argument('mame')
    ap.add_argument('first', nargs='?', type=int, default=0)
    ap.add_argument('last', nargs='?', type=int, default=10**9)
    ap.add_argument('--kmin', type=int, default=-30)
    ap.add_argument('--kmax', type=int, default=30)
    ap.add_argument('--k', type=int, default=None, help='skip the search')
    ap.add_argument('--show', type=int, default=8, help='worst frames to list')
    ap.add_argument('--mame-base', type=int, default=0,
                    help='absolute frame number of the MAME capture\'s frame 0 (its MS1_SKIP)')
    ap.add_argument('--recolour', action='store_true',
                    help='colour the core\'s frame through MAME\'s palette for that picture '
                         '(the core\'s i<N>.raw index dumps, MS1_IDX=1): MAME pairs a '
                         'composition with the NEXT frame\'s palette (MS1Z-5), so this is the '
                         'comparison that tests the composition alone')
    a = ap.parse_args()
    core = {}
    i = a.first
    while i <= a.last:
        f = load_core(a.core, i)
        if f is None: break
        core[i] = f; i += 1
    mame = {}
    j = 0
    while True:
        f = load_mame(a.mame, j)
        if f is None: break
        mame[j + a.mame_base] = f; j += 1
    print(f'core frames {min(core)}..{max(core)} ({len(core)}), MAME frames {min(mame)}..{max(mame)}')

    def score(k):
        ex = n = 0
        for i, f in core.items():
            m = mame.get(i + k)
            if m is None: continue
            n += 1
            if np.array_equal(f, m): ex += 1
        return ex, n
    ks = [a.k] if a.k is not None else range(a.kmin, a.kmax + 1)
    best = max(ks, key=lambda k: score(k))
    ex, n = score(best)
    print(f'best fixed offset k = {best:+d}: {ex}/{n} frames pixel-exact in the core\'s own palette')

    run = best_run = 0; run_start = best_start = None; rows = []
    for i in sorted(core):
        m = mame.get(i + best)
        if m is None: continue
        f = core[i]
        if a.recolour:
            ix = load_idx(a.core, i)
            pal = mame_palette(a.mame, i + best - a.mame_base)
            if ix is not None and pal is not None:
                f = pal[ix]
        diff = int(np.any(f != m, axis=2).sum())
        nonblank = int(np.any(f != 0, axis=2).sum())
        rows.append((i, diff, nonblank))
        if diff == 0:
            if run == 0: run_start = i
            run += 1
            if run > best_run: best_run, best_start = run, run_start
        else:
            run = 0
    print(f'longest exact run: {best_run} frames from core frame {best_start}')
    lit = [r for r in rows if r[1] == 0 and r[2] > 0]
    print(f'exact AND non-blank: {len(lit)} frames '
          f'(non-blank pixels min {min((r[2] for r in lit), default=0)}, '
          f'max {max((r[2] for r in lit), default=0)})')
    bad = sorted([r for r in rows if r[1]], key=lambda r: -r[1])[:a.show]
    for i, d, nb in bad:
        print(f'  core f{i} vs MAME f{i+best}: {d} differing pixels, {nb} non-blank')

if __name__ == '__main__':
    main()
