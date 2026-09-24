# Arcade-JalecoMS1Z_MiSTer

Jaleco **Mega System 1, type Z** for the MiSTer FPGA platform: **Legend of
Makai** (World) and **Makai Densetsu** (Japan), 1988. A 68000 at 6 MHz, a Z80
and a YM2203 for sound, two scrolling tilemap layers and 128 sprites.

Built from [Arcade-JalecoMS1BCD_MiSTer](https://github.com/kuzearcade/Arcade-JalecoMS1BCD_MiSTer)
-- the Mega System 1 B/C/D core, whose tilemap, sprite, palette and raster
blocks are shared with this one -- with the Z80 and YM2203 integration of
Arcade-NMK16_MiSTer and Arcade-SandScrp_MiSTer. `docs/provenance.md` says
where every file came from.

## Goals

- The board, verified against MAME: every claim in `docs/known-issues.md` is
  closed by a measurement, never by reasoning.
- Every feature of the MS1BCD core.

## Status

**In development; runs on the DE10-Nano.** Measured against MAME 0.289:

- **video block:** MAME's attract demo reproduced **pixel for pixel on 220 of
  220 frames** from MAME's own state (layers, sprites, palette, the raster
  split);
- **whole board from reset:** the title matches; the demo matches on 195 of
  220 frames, the rest differing by at most 16 sprite pixels on the top two
  rows (`docs/known-issues.md` MS1Z-12: sprites are drawn line by line from
  live RAM);
- **audio:** FM within 0.04 dB of MAME, the mix within 0.4 dB, band
  correlation 0.997 (MS1Z-13);
- **board:** boots to attract, savestates save and load, Flip screen exact,
  cheats work (`docs/hw-bringup.md`); 19,684 / 41,910 ALMs, 251 / 553 M10K,
  timing met.

See `docs/PLAN.md` for the plan and its gates.

## Supported games

| set | game | parent |
|---|---|---|
| `lomakai` | Legend of Makai (World) | -- |
| `makaiden` | Makai Densetsu (Japan) | `lomakai` |

## Features

Aspect ratio, Scandoubler Fx, Orientation, Flip screen (in the core), CRT
Adjust, DIP switches from the `.mra`, Pause, High Scores, seven cheats named
for the game, Autofire (hidden unless the `.mra` unlocks it --
`autofire_releases/`), four savestate slots, the MAME keyboard map. **F2** is
Service 1: on this board DSW2 bit 7 is the Invulnerability switch, not
service mode.

## Building

Quartus Prime 17.0 Lite: open `JalecoMS1Z.qpf` and compile, or
`quartus_sh --flow compile JalecoMS1Z`. Simulation needs Verilator 5:
`sim/rtl/ms1z_frames` (the whole board), `sim/rtl/video_state_z` (the video
block against one MAME frame). ROM images for the simulations are built from
your own romsets by `tools/mk_ms1z_images.py`; no ROM data is in this
repository or in the bitstream.

## Attribution

- **MAME** `jaleco/megasys1.cpp`, `megasys1_v.cpp`, `ms1_tmap.cpp` -- driver
  by **Luca Elia** and **David Haywood** -- the behavioural reference for
  every part of this core.
- **jt12 / jt03** (YM2203) and its **jt49** (SSG) -- Jose Tejada (Jotego).
- **T80** (Z80) -- Daniel Wallner, MikeJ, and Sorgelig's MiSTer maintenance;
  translated to Verilog with GHDL as NMK16 does.
- **fx68k** (68000) -- Jorge Cwik.
- **Hiscores** -- Alan Steremberg and Jim Gregory.
- **CRT Adjust** -- Umberto Parisi (rmonic79).
- **sdram.sv** -- Sorgelig.
- MiSTer **Template_MiSTer** / `sys/` framework.
- Cheats from Pugsy's MAME cheat database; high scores from MAME's
  `hiscore.dat`.
