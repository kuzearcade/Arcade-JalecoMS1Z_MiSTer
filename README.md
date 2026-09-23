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

**In development.** Simulated from reset, the whole board boots the real
program: the 68000, the Z80 and the YM2203 run, and the title screen and
attract demo draw. Measured against MAME 0.289:

- the video block reproduces MAME's attract demo **pixel for pixel on 220 of
  220 frames** (layers, sprites, palette, the raster split);
- the whole board matches MAME's title-screen frames, with the differences
  explained in `docs/known-issues.md` (MS1Z-5, MS1Z-10);
- the bitstream builds and meets timing: 19,192 / 41,910 ALMs, 399 / 553 M10K.

Not yet shown on hardware. See `docs/PLAN.md` for the plan and its gates.

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
