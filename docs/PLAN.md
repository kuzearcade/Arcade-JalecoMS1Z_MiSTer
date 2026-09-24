# Arcade-JalecoMS1Z_MiSTer — Project Plan (draft for review, 2026-09-23)

Jaleco **Mega System 1, type Z** (MAME `jaleco/megasys1.cpp` +
`megasys1_v.cpp` + `ms1_tmap.cpp`, driver by **Luca Elia** and **David
Haywood**) as a MiSTer FPGA core, built out of `Arcade-JalecoMS1BCD_MiSTer`
and taking its Z80 integration from `Arcade-NMK16_MiSTer`.

The method is unchanged from the three previous cores. RTL behaves like the
board, and MAME is the behavioural oracle. Verilator harnesses run before any
hardware work, and the DE10-Nano is the final proof. Every claim is closed by
a measurement.

**One `.rbf` — `Arcade-JalecoMS1Z` — one board, one game, two sets.**

| set | MAME description | main program | scroll 2 ROM | everything else |
|---|---|---|---|---|
| `lomakai` (parent) | Legend of Makai (World), 1988 | `lom_30.rom` / `lom_20.rom` | `lom_08.rom` | shared |
| `makaiden` (clone) | Makai Densetsu (Japan), 1988 | `makaiden.3a` / `makaiden.2a` | `makaiden.8` | shared |

| | Mega System 1-Z | for comparison: MS1-B/C (the existing core) |
|---|---|---|
| main CPU | 68000 @ **6 MHz** | 68000 @ 8 / 12 MHz |
| sound CPU | **Z80 @ 3 MHz** | 68000 @ 7 MHz |
| sound chips | **one YM2203 @ 1.5 MHz**, mono | YM2151 + 2x OKIM6295, stereo |
| tilemap layers | **2** | 3 |
| sprites | **128, drawn straight from Sprite Data, no Object RAM** | 256 through Object RAM |
| layer priority | **fixed** (MAME ignores the PROM) | 512-byte priority PROM |
| protection | **none** | TMP91640 MCU, iosim, or none |

**Status (2026-09-23): implementation under way.** What has been built and
measured, and where the measurements corrected this plan, is in
`docs/known-issues.md` (MS1Z-1 .. MS1Z-11) and `docs/checkpoint-*.md`. The
text below is the plan as drafted, with corrections marked where a
measurement overturned it.

- Section 0: the facts that shape the plan.
- Section 1: the hardware as MAME describes it, with source line references.
- Section 2: the architecture and a file-by-file reuse map.
- Section 3: milestones, tasks and gates.
- Section 4: every lesson from BCD, NMK16 and Sand Scorpion, mapped onto this
  board.
- Section 5: the risk register.
- Section 6: the open questions, each written as a measurement.
- Section 7: what to do on day one.
- Appendices: the OSD string, the savestate image map, and the M10K budget.

**Prerequisite that blocks M0: the ROMs.** `lomakai.zip` and `makaiden.zip`
are not on this machine (checked: `~/Arcade-JalecoMS1BCD_MiSTer/mame_roms/`,
`~/Downloads/`, the board's `/media/fat/games/mame/`). They go into
`~/Arcade-JalecoMS1Z_MiSTer/mame_roms/`, which is gitignored and never
committed. Every oracle capture, every harness and every gate depends on them.

---

## 0. Facts that shape the plan

1. **This is a separate core, not a fourth mode of MS1BCD, and the M10K
   budget alone decides it.** MS1BCD ships at **544 / 553 M10K (98 %)**.
   Adding a T80, a jt03, a Z80 program store and a Z-mode sprite path to that
   bitstream does not fit, even before timing is considered. MS1-44 found that
   the mode byte already fans out further than any other signal in that core.
   MAME also carries the split, in its own terms: `megasys1_typez_state`
   (`megasys1.h:245`) is a separate class with its own map, its own sprite
   routine and its own machine config.
2. **Most of the board is already built.** Of the MS1BCD parts, these carry
   over:
   - The tilemap layer (`ms1_tilemap.sv`). MS1-Z uses MAME's same
     `megasys1_tilemap_device`, with the same tile formats and the same
     scroll/control registers.
   - The palette format, `RRRRGGGGBBBBRGBx`, identical to B/C.
   - The sprite ROM format, `gfx_8x8x4_col_2x2_group_packed_msb`, identical.
   - The raster pipeline and the flip model (MS1-13).
   - The `ram_w` byte-mirroring rule.
   - The 68000, its park, the savestate engine, SDRAM, the caches, CRT
     Adjust, the hiscore and cheat modules, and every OSD feature.

   The Z80 side is already built too, in NMK16: T80 plus jt03, the Z80
   savestate park (`ss_z80_park.sv`, already present in MS1BCD's tree), the
   jt03 write stretch, the jt03 read-address fix, the Z80 read-mux
   qualification, the YM2203 register shadow and replay, and the GHDL-translated
   `T80s.v` for Verilator.
3. **What is genuinely new is small.**
   - The Z memory map and its interrupt levels.
   - A direct sprite walk (no Object RAM) in reverse order, with MAME's
     `prio_transpen` behaviour. Section 1.6 covers this; the behaviour is
     subtle.
   - A different palette-group assignment: sprites at `0x100`, layer 1 at
     `0x200`.
   - A fixed layer order, where BCD resolves the order through the PROM.
   - A sound board of Z80 + YM2203 with an 8-bit one-way latch.
4. **Every clock divides exactly out of 48 MHz.** 68000 6 MHz = /8, Z80
   3 MHz = /16, YM2203 1.5 MHz = /32, pixel 6 MHz = /8. There is no fractional
   accumulator anywhere, which rules out MS1-28's failure class (an
   accumulator one bit too narrow) by construction.
5. **MAME's System Z screen is a guess, and it differs from the B/C raster.**
   `system_Z` uses `set_refresh_hz(56.18)` over a **256-line** frame
   (`set_size(32*8, 32*8)`, visible rows 16-239, `set_vblank_time(0)`) and says
   "same as nmk16.cpp based on YT videos". B/C use `set_raw(6 MHz, 384, 0,
   256, 278, 16, 240)`. The frame rates agree to 0.04 % (56.20 Hz against
   56.18 Hz), but the **interrupt spacing does not**:

   | interval | MAME Z (256 lines) | core (278 lines) |
   |---|---:|---:|
   | IRQ3 → IRQ1 | 33,376 CPU cycles | 30,720 |
   | IRQ1 → IRQ2 | 60,077 | 55,296 |
   | IRQ2 → next IRQ3 (vblank work) | 13,350 | 20,736 |

   This plan ships the 278-line raster, the MS1 video family's own and the
   one the whole pipeline is built for, and adds a **sim-only** 256-line
   timing parameter. The parameter separates "raster model differs" from
   "bug" in the bus and sound gates. Section 6, Q4.
6. **MAME's latch interrupt to the Z80 does nothing.** `soundlatch_z_w`
   (`megasys1_v.cpp:275`) calls `set_input_line(5, HOLD_LINE)` on the Z80.
   The Z80's lines are IRQ0 = 0, WAIT = 1 and BUSREQ = 2 (`z80.h:12`), and
   `z80_device::execute_set_input` falls through `default: break;` for
   anything else. So in the oracle, the sound program either polls `0xE000`
   or reads it from the YM2203 timer interrupt. Whether the real board wires
   the latch to NMI decides the Z80 park design (the park itself uses NMI and
   overlays `0x0066`), so it is settled first, by disassembly. Section 6, Q1.
7. **MAME does not use the PROMs.** `makaiden.9` and `makaiden.10`
   (2 x 256 bytes) are "Unknown PROMs". `system_Z` has no palette init, so
   `priority_create()` never runs, and `screen_update` hard-codes
   `pri = 0x0314f` with `active_layers = 0x000b` for type Z. They still ship
   in the `.mra` under the no-baked-data rule, and they are decoded offline
   before M1 (Q3).
8. **No ROM or PROM data is ever compiled into the bitstream.** This rule
   carries over from MS1BCD (its section 2.3, NMK-22). Everything arrives from
   the user's `.mra` at run time.
9. **The ROM budget is tiny: 640 KB plus 512 bytes per set.** That is under
   a fifth of an MS1BCD set. Section 2.10 uses the freed block RAM to put the
   Z80's program window in BRAM rather than behind a cache.
10. **No protection, no MCU, no OKI.** `tlcs90/`, `ms1_iomcu.sv`, `jt51`,
    `jt6295` and `oki_rom_cache.sv` all drop out, along with MS1-2, -4, -5,
    -6, -8, -19, -24, -31, -43, -52, -54 and -55 as classes of problem.

---

## 1. The hardware, from the driver

All line numbers are `~/mame/src/mame/jaleco/*` at the checkout MS1BCD uses
(MAME 0.289 binary at `~/mame/mame`).

### 1.1 CPUs and clocks

| part | MAME | clock | from 48 MHz |
|---|---|---|---|
| main 68000 | `M68000(config, m_maincpu, SYS_A_CPU_CLOCK)` `megasys1.cpp:2255` | 6 MHz ("12MHz / 2") | /8, one phi edge every 4 clk |
| sound Z80 | `Z80(config, m_audiocpu, 3000000)` `:2259` | 3 MHz, commented "OSC 12MHz divided by 4 **???**" | /16 |
| YM2203 | `YM2203(config, "ymsnd", 1500000)` `:2285` | 1.5 MHz | /32 |
| pixel | (not given for Z; B/C `set_raw(6 MHz …)`) | 6 MHz | /8 |

The board notes list **OSC 5 MHz and 12 MHz** (`:2247`, `:3961`). Nothing in the
driver uses 5 MHz, and the Z80 clock is marked `???`. The YM2203 clock sets
the music tempo, so a wrong divider here is audible on hardware but invisible
against MAME. The core follows MAME and records it as unverified (Q2).

### 1.2 Main CPU memory map

`megasys1Z_map` = `megasys_base_map` (`:267-281`) + one latch write (`:251-255`).
`global_mask(0xfffff)`: 20-bit decode, like System B, and part of the decode
per MS1-21.

| range | r/w | what | notes |
|---|---|---|---|
| `000000-03FFFF` | R | program ROM, 256 KB | `ROM_LOAD16_BYTE` pair; watch MS1-49 (byte order) |
| `080000-080001` | R | `SYSTEM` | 16-bit; high byte unused → `0xFF` |
| `080002-080003` | R | `P1` | |
| `080004-080005` | R | `P2` | 16-bit: bits 8-15 "unknown/reserve" → `0xFF` |
| `080006-080007` | R | `DSW` | 16-bit: DSW1 = low byte, DSW2 = high |
| `084200-084205` | RW | layer 0 scroll X, Y, control | `scroll_r` exists: **readable** |
| `084208-08420D` | RW | layer 1 scroll X, Y, control | readable |
| `084300-084301` | W | `screen_flag` | bit 0 flip, bit 4 Z80 reset (§1.5) |
| `084308-084309` | W | sound latch | `data & 0xff`, §1.5 |
| `088000-0887FF` | RW | palette, 1024 entries | `RRRRGGGGBBBBRGBx` |
| `08C000-08DFFF` | RW | "Object RAM", **mirrored at `08E000`** | mapped as RAM, **never drawn from** on type Z |
| `090000-093FFF` | RW | layer 0 VRAM ("scroll1" → `m_tmap[0]`) | |
| `094000-097FFF` | RW | layer 1 VRAM ("scroll2" → `m_tmap[1]`) | |
| `0F0000-0FFFFF` | RW | work RAM, 64 KB, `ram_w` | **byte writes mirror into both halves** (`:257-265`) |
| `0F8000-0F87FF` | (RAM) | Sprite Data = work RAM + `0x8000` | 128 entries x 16 bytes |

Absent on Z, and so unmapped: `active_layers` (`084000`), `sprite_flag`
(`084100`), layer 2's scroll and VRAM, any sprite bank, any protection port,
and any main-CPU read of a sound reply. The latch is one-way.

The Object RAM window has to be real RAM even though nothing draws from it: a
boot RAM test that writes and reads it back must pass. Section 6, Q12 checks
whether the program touches it at all.

### 1.3 Interrupts

`megasys_base_scanline` (`:207-231`), `HOLD_LINE`, one scanline timer:

| raster line (MAME) | level | role (per the A-family notes in the same function) |
|---|---|---|
| 16 (`0 + 16`) | **3** | top of the visible area |
| 96 (`80 + 16`) | **1** | mid-screen raster |
| 240 (`224 + 16`) | **2** | vblank |

These differ from MS1BCD's B/C scheme (1 at 96, **4** at 240, 2 from the MCU
or the raster at 16). The IRQ block in `ms1_main.sv` takes the three raster
points and needs only a Z level table. HOLD_LINE semantics carry over from
MS1-23: one acknowledge **cycle** retires one interrupt.

### 1.4 Inputs and DIPs

`megasys1_generic` (`:819-860`) + `lomakai` (`:1496-1545`), all active low:

- `SYSTEM`: b0 Start 1, b1 Start 2, b5 **Service 1**, b6 Coin 1, b7 Coin 2.
- `P1`/`P2`: b0 right, b1 left, b2 down, b3 up, b4 Button 1, b5 Button 2.
  8-way. Two buttons.
- `DSW` low byte (DSW1):
  - b1:0 Lives (2/3/4/5, default 3)
  - b3:2 unused
  - b5:4 Difficulty (boss damage bar: Easy 6, Normal 8, Hard 9, Hardest 12 dots)
  - b6 Cabinet
  - b7 Flip Screen
- `DSW` high byte (DSW2):
  - b10:8 Coin A
  - b13:11 Coin B
  - b14 Demo Sounds
  - b15 **Invulnerability (Cheat)**

**Trap: MS1BCD's F2 key XORs DSW2 bit 7 as "service mode".** On this board
that bit is **Invulnerability**, so F2 is remapped (section 2.12).

### 1.5 Sound

`z80_sound_map` (`:798-804`), `z80_sound_io_map` (`:806-810`):

| Z80 space | range | what |
|---|---|---|
| mem | `0000-3FFF` | ROM, **16 KB mapped out of a 64 KB `lom_01.rom`** |
| mem | `C000-C7FF` | RAM, 2 KB, no mirror |
| mem | `E000` | R: sound latch, low byte |
| mem | `F000` | W: `nopw` ("??"), decoded and discarded |
| io (`global_mask 0xff`) | `00-01` | YM2203 address/status and data |

- **The latch** is `GENERIC_LATCH_16` written with `data & 0xff`. There is no
  second latch and no reply path.
- **YM2203**: `irq_handler().set_inputline(m_audiocpu, 0)` is the chip's
  IRQ line wired **level-sensitive** to Z80 INT, not HOLD_LINE.
  `add_route(ALL_OUTPUTS, "mono", 0.50)` sends FM and all three SSG channels
  to one speaker at 0.5.
- **Sound reset**: `screen_flag_w` (`megasys1_v.cpp:253-267`) holds the
  **Z80** in reset while bit 4 is set. The YM2151 reset and the OKI resets in
  the same function do **not** apply: the `ym2151_device` cast fails for a
  YM2203, and there are no OKIs. **So `screen_flag` bit 4 resets the Z80
  only.** Copying MS1BCD's MS1-30 wiring (reset the whole sound subsystem)
  would be wrong here.
- **YM2203 I/O ports A/B** have no callbacks in MAME. Their read value must
  match MAME's unconnected-port behaviour (Q11).

### 1.6 Video

**Layers.** Two `megasys1_tilemap_device`s, `m_tmap[0]` with palette base
`256*0` and `m_tmap[1]` with base `256*2` (`:2275-2277`). There is no layer 2
("Note: missing on MS1-Z", `megasys1_v.cpp:13, 35`). Tile format, 8x8/16x16
select and page layout are identical to B/C. The ROMs are smaller:
- scroll1 128 KB = 4096 8x8 tiles, exactly the 12-bit code.
- scroll2 64 KB = **2048 tiles**, so a 12-bit code **wraps** (MAME takes
  `code % elements`).

**Palette groups** (`megasys1_v.cpp:79-92`, and the `GFXDECODE` bases):

| index | B/C (MS1BCD today) | **Z** |
|---|---|---|
| `000-0FF` | layer 0 | layer 0 |
| `100-1FF` | layer 1 | **sprites** |
| `200-2FF` | layer 2 | **layer 1** |
| `300-3FF` | sprites | unused |

**Sprites** (`megasys1_typez_state::draw_sprites`, `megasys1_v.cpp:425-458`):

- Source: **live work RAM** at `m_ram + 0x8000/2`, 128 entries of 16 bytes.
  There is no Object RAM indirection, and the vblank double-buffer
  (`screen_vblank`) is not even wired in `system_Z`. So MAME draws with
  **zero frames of sprite latency**, where B/C have two.
- Fields:
  - `attr = w[4]`: bit 7 flip Y, bit 6 flip X, bit 3 "priority", bits 3:0
    colour.
  - `sx = sext9(w[5])`, `sy = sext9(w[6])`.
  - `code = w[7]`: 16 bits, wrapping modulo the 1024 tiles in a 128 KB
    sprite ROM.
- No mosaic, no split, no bank, no trails.
- Order: `for (sprite = 0x7f; sprite >= 0; sprite--)` through
  `prio_transpen(…, BIT(attr,3) ? 0x0c : 0x0a, 15)`. **Corrected by
  measurement (MS1Z-7):** `prio_transpen` ORs bit 31 into the mask, so the
  first sprite to reach a pixel keeps it and the **highest index is in
  front**, exactly as the driver's header comment says. This plan's first
  draft read it as a painter's order and was wrong.
- Screen flip: `sx = 240 - sx`, `sy = 240 - sy`, flips toggled. That is
  consistent with MS1-13's "flip is rot180 of the finished frame".

**Priority** (`screen_update`, `megasys1_v.cpp:740-800`). With
`pri = 0x0314f` and `sprite_flag == 0` the order is layer 0 (drawn opaque) <
sprites < layer 1, and attribute bit 3 has no effect (both masks hide a
sprite under layer 1). The first draft described a "shows through layer 1"
quirk here; it does not exist -- a sprite hidden under layer 1 still owns its
pixel (MS1Z-7). 220 / 220 demo frames are pixel-exact with the plain stack.

**When MAME renders.** With `set_vblank_time(0)` the whole frame is composed at
line 240 from the RAM state at that instant. The core races the beam for the
tilemaps, as MS1BCD does. MS1-11 and MS1-12 (the oracle's registers lag its
VRAM; one snapshot per frame cannot reproduce every frame) and Sand Scorpion's
SS-11 (mid-frame palette writes tear on the core and not in MAME) all apply
unchanged.

### 1.7 ROMs

`ROM_START( lomakai )` / `( makaiden )`, `megasys1.cpp:3966-4010`:

| region | size | lomakai | makaiden |
|---|---:|---|---|
| maincpu | `0x40000` | `lom_30.rom` even `ba6d65b8`, `lom_20.rom` odd `56a00dc2` | `makaiden.3a` even `87cf81d1`, `makaiden.2a` odd `d40e0fea` |
| audiocpu | `0x10000` | `lom_01.rom` `46e85e90` | same |
| scroll1 | `0x20000` | `lom_05.rom` `d04fc713` | same |
| scroll2 | `0x10000` | `lom_08.rom` `bdb15e67` | `makaiden.8` `a7f623f9` |
| sprites | `0x20000` | `lom_06.rom` `f33b6eed` | same |
| proms | `0x200` | `makaiden.9` `3567065d` @0, `makaiden.10` `e6709c51` @`0x100` | same |

`makaiden` is a clone, so its `.mra` names `makaiden.zip|lomakai.zip`. The
local zips must be checked against these CRCs, including MAME 0.289 filename
changes (MS1-7) and `BAD_DUMP` parts (MS1-3).

---

## 2. Architecture and reuse

### 2.1 How the code is shared

MS1BCD was built by copying NMK16's proven files into a new repo and pinning
third-party code in `deps.lock`. This core does the same, with one refinement:
**the four `rtl/jaleco/` video files stay textually shared with MS1BCD.** Z
behaviour sits behind a compile-time `parameter BOARD_Z = 0`, not a runtime
mode. That keeps `diff ~/Arcade-JalecoMS1BCD_MiSTer/rtl/jaleco
~/Arcade-JalecoMS1Z_MiSTer/rtl/jaleco` meaningful, so a later fix of the
MS1-57/59/60 kind can be ported as a patch in either direction. A parameter
rather than a mode also means none of the Z logic costs MS1BCD anything, the
opposite of MS1-44.

Board-level files (`ms1z_core`, `ms1z_main`, `ms1z_sound`, `ms1z_rom_hw`, the
top level) are new files derived from their MS1BCD counterparts. They are not
kept in sync.

A `docs/provenance.md` records, for every copied file, the source repo, the
commit it came from, and whether it is verbatim, parameterised or derived.

### 2.2 Repository layout

    Arcade-JalecoMS1Z_MiSTer/
      MS1Z.sv                        top level (from MS1BCD.sv)
      JalecoMS1Z.qpf/.qsf/.sdc       project (from JalecoMS1BCD.*)
      files_ms1z.qip
      deps.lock, LICENSE, README.md, .gitignore
      rtl/ms1z/      ms1z_core.sv    the board: main + sound + video + savestate
                     ms1z_main.sv    68000, Z decode, IRQ, latch, work/obj RAM
                     ms1z_sound.sv   T80 + jt03 + latch + Z80 RAM/ROM + YM shadow
                     ms1z_rom_hw.sv  SDRAM side: caches, arbiters, download
                     ms1z_rom_map.vh GENERATED by tools/gen_rom_map.py
      rtl/jaleco/    ms1_tilemap.sv  shared with MS1BCD (parameterised)
                     ms1_sprites.sv  shared (BOARD_Z direct-walk path)
                     ms1_video.sv    shared (BOARD_Z palette + fixed order)
                     ms1_prio.sv     only if Q3 proves the PROM is priority
      rtl/savestate/ savestate.sv, savestate_ui.sv, ss_m68k_park.sv,
                     ss_z80_park.sv  (engine and both parks, verbatim)
      rtl/           sdram*.sv, rom_cache*.sv, tile_prefetch_byte.sv,
                     video_retime.sv, crt_chain.sv, cheats.sv, pll*.v
      rtl/third_party/      fx68k, jt12 (jt03 + nested jt49), t80,
                            hiscore, crt_adjust   (fetched, pinned)
      rtl/third_party_gen/t80/T80s.v + ghdl-compat.patch  (sim only, tracked)
      sim/models/sdram_model.sv
      sim/oracle/    ms1z_capture.lua, ms1z_bustrace.lua, ms1z_soundtrace.lua
      sim/rtl/       ms1_frames, ms1_hw, ms1_snd, ms1_bus, video_state,
                     tilemap_test, ss_z80 (from NMK16)
      tools/         generators, extractors, comparators (section 2.13)
      tools/mame-patches/  megasys1z-sound-isolation.patch
      releases/      .mra files + the current .rbf
      docs/          PLAN.md, provenance.md, known-issues.md (MS1Z-n),
                     hw-bringup.md, m*-gate*.md, checkpoint-*.md

### 2.3 Reuse map

**From MS1BCD, verbatim** (byte-identical; any later change is a deliberate
fork, logged in `provenance.md`):

| file | why it transfers |
|---|---|
| `rtl/sdram.sv` (modified, tracked), `sdram_req.sv`, `sdram_arb.sv` | same controller, 96 MHz, `REFRESH_CYCLES(740)`, pair reads |
| `rom_cache1.sv`, `rom_cache1_byte.sv`, `rom_cache_n.sv`, `rom_cache_n_byte.sv`, `tile_prefetch_byte.sv` | same main-CPU and tile-fetch problems |
| `video_retime.sv` (VTOTAL 278), `crt_chain.sv`, `third_party/crt_adjust` (modified `crt_vsize.sv`) | same raster |
| `rtl/savestate/savestate.sv`, `savestate_ui.sv`, `ss_m68k_park.sv`, `ss_z80_park.sv` | same engine; the Z80 park is NMK16's, already carried in MS1BCD |
| `third_party/hiscore` (modified: validation pass, M10K-inferring `dpram_hs`) | same |
| `third_party/fx68k` | one instance now |
| `pll.v`, `pll_video96.v`, `sys/` | same clocks |
| `sim/models/sdram_model.sv` | |
| `tools/`: `mister_keys.py`, `mister_sweep.sh`, `board_feature_test.py`, `audio_compare.py`, `frame_compare.py`, `compare_frames.py`, `bus_compare.py`, `mk_ioctl_stream.py`, `mkgfxrom.py`, `gen_autofire_mra.py` (INCLUDED list edited), `run_*.sh`, `bootstrap.sh` | |

**From MS1BCD, parameterised** (shared text, `BOARD_Z` guarded):
`ms1_tilemap.sv` (region-size masks for wrap), `ms1_sprites.sv`,
`ms1_video.sv`.

**From MS1BCD, derived** (new file, same structure):

| new file | from | what changes |
|---|---|---|
| `MS1Z.sv` | `MS1BCD.sv` | CONF_STR (Appendix A), no mode/prot fields, F2 remap, cheat names, button list, no OKI/MCU plumbing, RGB_LAT kept (MS1-59) |
| `ms1z_core.sv` | `ms1bcd_core.sv` | no MCU, no OKI ports, Z80 ROM port, savestate map (Appendix B) |
| `ms1z_main.sv` | `ms1_main.sv` | Z decode (§1.2), 6 MHz phi, IRQ 3/1/2, 16-bit input ports, no protection, latch write, Object RAM as plain RAM; keeps `ram_w` mirroring, pause-on-enPhi2 (MS1-39/NMK-24), hiscore back door, `spr_buf_busy` |
| `ms1z_sound.sv` | `ms1_sound.sv` skeleton + NMK16 `tdragon2_core.sv` Z80 block | T80s, jt03, 8-bit latch, Z80 RAM, 16 KB Z80 ROM in BRAM, YM2203 shadow and replay |
| `ms1z_rom_hw.sv` | `ms1bcd_rom_hw.sv` | four SDRAM regions, no OKI caches, Z80 window tapped into BRAM during download |
| `gen_ms1z_mra.py` | `gen_ms1bcd_mra.py` | two sets, `alt_dir_name()` kept (no parentheses), `carry_over()` kept |
| `ms1z_romdata.py`, `ms1z_dipdata.py` | `ms1_romdata.py`, `ms1_dipdata.py` via `extract_ms1_roms.py` / `extract_ms1_dips.py` | point the extractors at `system_Z` |
| `gen_rom_map.py` | same | one layout, no modes |
| `gen_hiscore_mra.py` | same | **accept `:ram/share,<offset>` records** (§2.12) |
| `gen_cheats_mra.py` | same | Makai slot table; 3-action and masked actions |
| `dump_video_state.py`, `ms1_video_model.py` | same | Z palette groups, direct sprites (127→0, first writer wins), fixed order |
| `sim/oracle/*.lua` | same | Z addresses; Z80 I/O-port taps for the sound trace; no MCU trace |
| `sim/rtl/*` harnesses | same | Z top, T80s.v in the Verilator file list, `RTLSRC` wildcard (MS1-58) |
| `megasys1z-sound-isolation.patch` | MS1BCD `megasys1-sound-isolation.patch` + SandScrp `sandscrp-ym-isolation.patch` | `MS1_SND_ISO=fm|ssg` on the YM2203 |

**From NMK16, for the Z80** (section 2.5 has the details):

| item | NMK16 source |
|---|---|
| T80 pin, `deps.lock` line | `t80 … 830fd031…` |
| jt12 pin (jt03 + nested jt49 submodule) | `jt12 … 3a4c423f…` |
| `rtl/third_party_gen/t80/T80s.v`, `ghdl-compat.patch`, `tools/gen_t80_verilog.sh`, `docs/t80-vhdl-toolchain.md` | Verilator cannot read VHDL; the real T80 is translated once |
| Z80 bus decode and read mux | `tdragon2_core.sv:1874-1895, 2330-2343` |
| jt03 write stretch + read-address fix | `tdragon2_core.sv:2018-2060`; `docs/tier2-system.md:4453` |
| YM2203 shadow + replay FSM | `tdragon2_core.sv:2346-2406` |
| `sim/rtl/ss_z80` (park proof harness) | NMK16 |

**Dropped** from MS1BCD: `rtl/tlcs90/`, `jaleco/ms1_iomcu.sv`, `jaleco/ms1_prio.sv`
(unless Q3 changes that), `oki_rom_cache.sv`, `rom_cache*` instances for the
OKIs, `third_party/jt51`, `third_party/jt6295`, `sim/rtl/iomcu`,
`sim/rtl/tlcs90`, `sim/oracle/ms1_mcutrace.lua`, `tools/prot_compare.py`,
`tools/gen_ms1bcd_ioctl.py` (replaced by a Z version), and every mode and
protection field.

### 2.4 The main board — `ms1z_main.sv`

1. **Decode**: §1.2's table, `amask = 24'h0FFFFF` applied before any compare
   (MS1-21). Unmapped reads return what MAME's 68000 space returns (checked
   under Q13, not assumed). Unmapped writes are dropped.
2. **Clock**: `phdiv_max = 3` (48/8 = 6 MHz). enPhi1/enPhi2 strictly
   alternate. Pause is re-timed onto enPhi2 (MS1-39, NMK-24 root cause).
3. **IRQ**: the raster points 16/96/240 raise levels 3/1/2. Each is a
   HOLD_LINE retired by one acknowledge cycle (MS1-23). The park's `ipl_park`
   overrides them as in MS1BCD.
4. **Inputs**: 16-bit ports. SYSTEM high byte and P1 high byte read `0xFF`;
   P2 bits 8-15 read `0xFF` (MS1-42: no port is squeezed through an 8-bit
   mux).
5. **Work RAM**: 32K x 16 BRAM with byte-write mirroring, a second port for
   the hiscore and cheat back door, and the sprite-buffer copy source.
6. **Object RAM**: 4K x 16 plain RAM at `08C000`, mirrored at `08E000`.
7. **Video registers**: two scroll triples, both readable; `screen_flag`
   (bit 0 → video flip, composed with OSD flip; bit 4 → `z80_reset`).
8. **Latch**: `084308` write → an 8-bit `soundlatch` (low byte), no IRQ
   (fact 6, pending Q1).
9. **Sprite snapshot**: at `vblank_rise`, copy work RAM `0x0F8000-0x0F87FF`
   (1K words) into the sprite engine's buffer through the existing
   `buf_busy` path. Z uses **one** stage, not B/C's two (§1.6, zero latency).
   *As built (MS1Z-12): no snapshot. `rtl/ms1z/ms1z_sprline.sv` reads live
   work RAM while each line is drawn, because lomakai rewrites its list during
   the first ~100 lines of the frame and a vblank snapshot showed it a frame
   late.*

### 2.5 The sound board — `ms1z_sound.sv`, with NMK16's Z80 specifics

1. **CPU**: `T80s` (VHDL for Quartus, `T80s.v` for Verilator),
   `CEN = z80_cen & ~pause`, `z80_cen` = every 16th clk.
   - `RESET_n = ~reset & ~screen_flag[4]` (Z80 only, §1.5).
   - `NMI_n = ~z80_nmi_park`, ANDed with the game's own NMI if Q1 finds one.
   - `INT_n = ym_irq_n`, level-sensitive, as MAME wires it.
2. **Memory**:
   - ROM `0000-3FFF` from a 16 KB BRAM filled during the download (§2.10),
     so no WAIT_n and no cache.
   - RAM `C000-C7FF`, 2 KB, as byte lanes the savestate engine can move a
     word at a time (NMK16's `z80_ram_e/_o`).
   - `E000` read → latch; `F000` write → dropped.
   - `C800-DFFF` and `4000-BFFF` unmapped, returning MAME's unmap value
     (Q7, Q13).
3. **The read mux qualifies every memory select with `z80_mem_re` and every
   port select with `z80_io_re`.** An `IN A,(n)` drives A onto A15-A8, and
   NMK16 shipped a silent-music bug because a memory decode answered an I/O
   read (NMK-14, `hw-bringup.md` "the Z80 read mux").
4. **I/O**: ports `0x00`/`0x01` on `z80_a[7:0]`, `IORQ` qualified.
5. **jt03**: `cen` = every 32nd clk (1.5 MHz).
   - Writes use NMK16's **40-cycle write stretch, with the YM's own held
     `a0`/`din` captured at the write edge.** That closes, by construction,
     the latent shared-latch window MS1-62 left open in MS1BCD.
   - Reads use **the live port decode for `addr` unless a write stretch is in
     flight** (NMK16 `tier2-system.md:4453`). Otherwise a busy poll after a
     data write reads the SSG data register and the driver spins.
   - `IOA_in`/`IOB_in` per Q11.
6. **Mix**: MAME routes FM and each SSG channel at 0.5 into one speaker.
   `jt12_top` sums `fm + {psg, 5'd0}`. Sand Scorpion measured that its own
   `>>> 1` on the combined term lands FM at MAME's routed level, and that
   halving the FM again made every band worse (SS-10, `3f4ac90`). **Start from
   Sand Scorpion's mix and change it only on a measurement against the
   isolated halves.** Mono out, duplicated to L and R.
7. **Debug taps** on the module boundary from the first commit:
   `dbg_ym_writes`, `dbg_fm_snd`, `dbg_psg_snd`, `dbg_z80_pc`, `dbg_acc`,
   `dbg_addr`. MS1BCD's `ms1_snd` harness and SS-10's isolation both depended
   on taps like these.

### 2.6 Shared video blocks and `BOARD_Z`

`ms1_video.sv`:
- `nlayers = 2`.
- `pal_idx` for Z: layer 0 → `{2'd0,…}`, sprites → `{2'd1,…}`, layer 1 →
  `{2'd2,…}`.
- Palette format as B/C.
- `active_layers` tied to `0x000B`.
- The priority stage replaced by the fixed order (corrected, MS1Z-7):

      pix = l1_opaque  ? L1
          : spr_opaque ? SPR
          :              L0      // layer 0 is drawn opaque

*As built (MS1Z-12), Z does not use `ms1_sprites.sv` any more: `ms1_video`
takes `EXT_SPR = 1` and `ms1z_sprline.sv` draws each line from live Sprite
Data into a ping-pong line buffer, one line ahead of the beam (the same
127 → 0 first-writer-wins order, code and position rules as below). The
`BOARD_Z` path below still exists in the shared file and was what
MS1Z-7's 220/220 was measured on.*

`ms1_sprites.sv` (`BOARD_Z`):
- Skip the Object RAM walk. Walk Sprite Data entries **0 → 127** into a
  first-writer-wins plane; that equals MAME's 127 → 0 painter's order.
- No bank-match test, no mosaic, colour = `attr[3:0]`,
  code = `w[7] & 10'h3FF` (1024 tiles), `sext9` positions.
- ~~Plane bit 8 becomes `cov2`~~ -- dropped: there is no such quirk
  (MS1Z-7). The walk is 127 → 0 and plane bit 8 is unused on Z.
- MS1-60's beam-paced clear and the pass budget carry over. The Z pass is
  128 x 256 = 32,768 pixel visits against a 165,888-clock budget, about 20 %.
- If Q3 or Q5 later shows attribute bit 3 matters on hardware, the plane goes
  to 10 bits (about +64 M10K for two copies; affordable, Appendix C).

`ms1_tilemap.sv`: add a per-instance ROM-size mask, so layer 1's 2048-tile ROM
wraps the way MAME's `code % elements` does instead of reading into the next
SDRAM region.

### 2.7 SDRAM, BRAM and download

| region | SDRAM byte base | size | notes |
|---|---|---|---|
| maincpu | `0x000000` | `0x40000` | via `rom_cache_n`; held address when not selecting ROM (MS1-50, SS-12) |
| audiocpu | `0x040000` | `0x10000` | stored whole; **the first `0x4000` also tapped into a 16 KB BRAM** during download |
| scroll1 | `0x050000` | `0x20000` | `tile_prefetch_byte`, LOOKAHEAD path (MS1-57) |
| scroll2 | `0x070000` | `0x10000` | same, with the wrap mask |
| sprites | `0x080000` | `0x20000` | sprite fetcher |
| **total** | | **`0x0A0000` = 640 KB** | |
| PROMs | BRAM, ioctl index 1 | `0x200` | kept even if unused (fact 7) |

ioctl indices are MS1BCD's: 0 ROM, 1 PROM, 3 hiscore, 5 cheats, 254
switches. The download carries SS-12's rules forward: `ioctl_wait`
backpressure from the port busy, a write request held until complete, and
every cache in reset for the whole download.

Why BRAM for the Z80 window: it is 16 KB (about 13-16 M10K), the budget has
room (Appendix C), and it removes NMK16's worst Z80 bug class, where a
cache's fill timing decided whether a busy-poll chain terminated. The SDRAM
copy stays so the fallback is a one-line change.

### 2.8 Savestates

The engine is `savestate.sv`, unchanged, with four slots at `0x3E000000` of
`0x80000` bytes each. The image map is Appendix B.

- **68000**: `ss_m68k_park` (SSP/USP; the rest on the stack in work RAM).
- **Z80**: `ss_z80_park`. NMI pulls into a 93-byte monitor overlaid at
  `0x0066`, IM is snooped from M1 fetches, and SP and IM are held in the
  state registers. **Depends on Q1**: if the game's own NMI handler lives at
  `0x0066`, the park/game-NMI interaction needs NMK16's `sim/rtl/ss_z80`
  proof re-run against this ROM before it is wired in.
- **YM2203**: a 256-byte register shadow, replayed on load with NMK16's
  scheme (0x28 key-on replaced by a key-off sweep; 0x2C-0x2F handled per Q14).
  **MS1BCD's two savestate audio bugs are acceptance rules here, not
  lessons:**
  1. MS1-62: **the shadow captures from the live bus at the write edge**
     (`ym_a0_src`/`ym_d_src` in NMK16's form), never from a shared "last
     write" latch.
  2. MS1-61: **nothing the replay depends on is frozen by `ss_hold`**. jt03's
     `cen` keeps running through `S_REPLAY`, and the replay FSM **releases
     the chip when `ss_replay` drops, finished or not**.
  3. The `ms1_snd` harness has the `MS1_SS_AT=<frame>` savestate cycle and
     `MS1_TRACE_FROM` from its first version. The M3 gate includes "writes
     continue at the pre-save rate after a restore" at a frame where the
     driver is actually playing.
- **Every restore lives inside the always block that owns the register**
  (MS1-34, caught by `quartus_map` per MS1-38).
- **Park on the vblank edge in every harness**, as the engine does. MS1-61
  hid in a harness that parked at an arbitrary tick.

### 2.9 Feature parity with MS1BCD

Every feature of MS1BCD is supported. How each maps:

| feature (MS1BCD) | on MS1-Z |
|---|---|
| Aspect ratio, Scandoubler Fx, hidden under direct video | unchanged |
| Orientation Horz / Vert 90 / Vert 270, hidden under direct video | unchanged (both sets are ROT0; kept for rotated cabinets) |
| Flip screen in the core, composed with `screen_flag[0]` | unchanged (MS1-13 model) |
| CRT Adjust page (H-Size, H-Position, V-Shift, V-Size, V-Size Mode) | unchanged |
| 5-pixel video alignment (`RGB_LAT`, MS1-59) | unchanged; re-measured on the board at M4 |
| DIP menu from `.mra` `<switches>` | DSW1/DSW2 from §1.4 |
| Pause (68000 on enPhi2, sound CPU gated, chips free-running) | T80 `CEN` gated the same way |
| High Scores (Save/Reset, greyed out while Off) | `hiscore.dat` has `lomakai`/`makaiden` (`hiscore.dat:6023`); see the trap below |
| Cheats, 7 slots, hidden per slot by menumask | **game-named slots** (one game per core): Infinite Lives, Infinite Energy, Infinite Time, Infinite Money, Infinite Jumps, Invincibility, Always Have All Keys; the data is identical for both sets |
| Autofire P1/P2, hidden unless `<switches>` byte 2 bit 7 | unchanged; on this board Button 3 has no game function, so the "Button 3 becomes a plain Button 1" trade costs nothing |
| `autofire_releases/` mirror, git-ignored | both sets included (the only game; opt-in via the mirror) |
| Savestates, 4 slots, F1/F5/F3/F4, Alt to save, info messages | unchanged (§2.8) |
| Service key (F2) | **remapped to `SYSTEM` b5 (Service 1)**; never DSW2 b7, which is Invulnerability here |
| MAME keyboard map (`mister_keys.py` with the chord fix) | unchanged |
| `J1` button list, positionally matched to `.mra` `<buttons>` | `Button 1,Button 2,Button 3,Start,Coin` (Button 3 = autofire alias) |
| `sw_seen` gating: the core waits for `<switches>` (MS1-47, MS1-53) | kept; there is no mode byte to be idle, but the DIPs still arrive late |
| `releases/` `.rbf` named `Arcade-JalecoMS1Z_<BUILD_DATE>.rbf` | unchanged |
| `_alternatives/_<Parent>/` without parentheses | `_alternatives/_Legend of Makai/Makai Densetsu (Japan).mra` |
| kuzecores publication | new `CORES` entry in `~/kuzecores/tools/update_external_files.py` |

**High-score trap:** `hiscore.dat` gives these sets in the share-relative form
`@:maincpu,:ram/share,f000,2,00,03`. `gen_hiscore_mra.py` today reads field 2
as an absolute CPU address and would emit `0x00F000`, which is ROM. The
records are offsets into `m_ram`, so they become `0x0FF000`, `0x0FF002` and
`0x0FE060`. The generator must translate `:ram/share` records, and an M5 test
proves a score survives a power cycle.

**Cheat engine trap:** `cheats.sv` does plain byte/word pokes with
`ACTS = 2`.
- **Infinite Time** is three byte writes at odd addresses 2 apart
  (`FC01B/D/F`), which cannot be merged into words.
- **Always Have All Keys** is a masked OR (`03|(x BAND ~03)`).

Either `ACTS` goes to 3 and a read-modify-write action type is added, using
the shared port's read side that the hiscore module already uses, or those two
slots are replaced by plain-poke cheats from the same file. The plan takes the
extension, verified by a sim test and on the board.

### 2.10 Tools, `.mra`, releases

- **`gen_ms1z_mra.py`**: one table, two sets.
  - The parent goes at the top level.
  - The clone goes in `_alternatives/_Legend of Makai/`.
  - ROM parts carry CRCs from §1.7, with the 68000 pair interleaved in the
    right byte order (MS1-49).
  - `<switches>` carries the three bytes: DSW1, DSW2, and a flags byte with
    [7] = autofire unlock and the rest spare.
  - `<buttons>`.
  - The PROM part at index 1, the hiscore block (index 3) and the cheat table
    (index 5), both preserved across regeneration by `carry_over()`.
- `gen_autofire_mra.py`: `INCLUDED = ("Legend of Makai",)`. It covers the
  clone through its directory.
- `mkgfxrom.py`: the same two formats as B/C.
- `gen_rom_map.py` writes `ms1z_rom_map.vh` from `ms1z_romdata.py`.
- Committed board tooling: `tools/mister_sweep.sh`, `board_feature_test.py`
  (drives options through `<setname>.CFG` and `.dip`), and `mister_keys.py`.

### 2.11 No baked ROM or PROM data

The rule and its gate are MS1BCD's section 2.3 verbatim:
- No `$readmemh` outside an `HW_ROMS == 0` guard.
- No `.mif` or `.hex` in the `.qip`.
- The PROM byte sequence and a sample of every ROM region absent from the
  `.rbf`, checked by a script at M4.
- The Z80 BRAM is filled from the ioctl stream, never initialised.

---

## 3. Milestones, tasks and gates

Each milestone ends with a stated, measured gate. "Sim passed" is never the
last word for the memory path, the park/resume path or byte order; those need
the board. Every gate result goes into a `docs/m<N>-gate*.md` with the
numbers.

### M0 — Foundation

1. `git init`. `.gitignore` from MS1BCD: `/mame/`, `/mame_roms/`,
   `/autofire_releases/`, `output_files*/`, sim build dirs, frame dumps,
   `**/roms/*.bin`, oracle traces.
2. `deps.lock`: MS1BCD's `template_mister`, `fx68k`, `sdram`, `hiscore` and
   `crt_adjust` pins, plus NMK16's `t80` and `jt12` pins (with the nested
   jt49 submodule). `jt51` and `jt6295` removed.
   - `bootstrap.sh`, then copy the tracked, modified files (`sdram.sv`,
     `hiscore`, `crt_vsize.sv`) from MS1BCD, **not** from upstream.
   - Carry the GPL-2.0-only Template vs GPL-3.0 flag from MS1BCD's
     `deps.lock` into this one; it must be resolved before a public release.
3. Copy the verbatim set (§2.3) with `provenance.md`, and the T80 translation
   assets from NMK16. Prove NMK16's `sim/rtl/ss_z80` still builds and passes
   here.
4. Obtain `lomakai.zip` and `makaiden.zip`. Check every part against §1.7's
   CRCs, sizes, `BAD_DUMP` flags and 0.289 names (MS1-3, MS1-7).
5. Extractors and data: `ms1z_romdata.py`, `ms1z_dipdata.py`, `gen_rom_map.py`,
   and `gen_ms1z_mra.py` with the off-board load model.
6. **Answer Q1, Q3, Q7 and Q12 offline**, before any RTL:
   - Disassemble `lom_01.rom` (reset, `0x0038`, `0x0066`, the latch reads)
     and the 68000 program's IRQ vectors and RAM test.
   - Decode the PROMs with MAME's `priority_create()` logic.
7. MAME oracle captures for `lomakai`, with the SDL environment variables set
   (MS1-14), absolute `-rompath` (MS1-26), and no forced DIP left in `cfg/`
   (MS1-25):
   - attract, 2400 frames;
   - scripted play: coin, start, walk, attack, jump, take a hit, reach the
     first boss;
   - a DIP sweep: Flip Screen, Lives, Demo Sounds;
   - a flipped attract;
   - the sound trace (latch writes with absolute clocks, `screen_flag` bit 4
     transitions, YM2203 port writes);
   - the main bus trace.

   Reuse `ms1_capture.lua`, remembering that `pixels()` returns three values
   (MS1-9) and that write taps are removed on garbage collection (MS1-10).
8. The clock plan and raster, written down (§1.1, fact 5).

**Gate**: the copied tests build and pass. `.mra` part CRCs match the zips,
and the load model agrees with the generator. Oracle frames, the bus trace
and the sound trace exist for `lomakai` and `makaiden`. Both `.mra` files
carry the real PROMs. Q1, Q3, Q7 and Q12 have written answers.

### M1 — Video against MAME state

1. Parameterise `ms1_tilemap`, `ms1_sprites` and `ms1_video` (`BOARD_Z`), with
   MS1BCD's own gates re-run on the shared files unchanged (`BOARD_Z = 0`
   must not move one MS1BCD pixel).
2. `video_state` harness: MAME RAM dump (VRAM x 2, palette, scroll regs,
   `screen_flag`, work RAM `F8000-F87FF`) → frame.
3. `ms1_video_model.py` Z path (walk order per MS1Z-7), as an independent
   second implementation.

**Gate**: pixel-exact against MAME's own frame, with non-blank pixel counts
reported beside every match, for:
- a 16x16-tile scene and an 8x8-tile scene;
- a non-default page layout;
- sprites over layer 0 and under layer 1;
- **a pixel where two sprites overlap, one partly under opaque layer 1** (the order check, MS1Z-7).
  Found in play captures, or built by poking work RAM from Lua;
- the scroll2 wrap (a tile code ≥ 2048 if the program ever emits one, or a
  synthetic poke);
- a flipped frame.

And: MS1BCD's `video_state` gate still passes with `BOARD_Z = 0` on the
shared files.

### M2 — Full reference sim

1. `ms1z_main`, `ms1z_sound`, `ms1z_core` in the `ms1_frames` harness
   (LOOKAHEAD 0).
2. `ms1_snd`: T80 + jt03 driven by MAME's latch log and `screen_flag[4]` log
   with absolute clocks. It includes `MS1_SS_AT`, `MS1_TRACE`,
   `MS1_TRACE_FROM`, `MS1_BUSLOG`, `MS1_COUNTS` and `MS1_WAV` with per-source
   taps.
3. `ms1_bus`: main-CPU trace compare, with the 256-line sim parameter (fact 5)
   available for alignment.

**Gates**:
1. Main-CPU bus trace against MAME through boot, as far as the first
   interrupt that lands apart (MS1-22), run under **both** raster models.
2. Frames pixel-exact over the attract at a fixed offset, reported as a run
   length (MS1BCD M2 gate 2 format).
3. YM2203 writes per frame against MAME's sound trace, frame by frame. Every
   difference must be explainable as a frame-boundary slip, as in
   `m2-gate34.md`.
4. Audio band correlation ≥ 0.95 with **FM and SSG isolated separately**,
   using the patched MAME (`MS1_SND_ISO=fm|ssg`). Report level offsets per
   band. The boot-burst check from SS-10 is part of this gate.
5. The Z80's hottest addresses over the attract: no spin loop that MAME does
   not also show.

### M3 — Hardware-path sim

1. `ms1_hw`: real `sdram.sv` + model, ioctl stream in loader order,
   LOOKAHEAD 8.
2. The savestate round trip in `ms1_frames` (vblank-aligned park,
   `MS1_SS_YMDIV`-style phase forcing for every free-running divider jt03 and
   the parks depend on).

**Gates**:
- Golden-byte audits, 0 wrong, for every SDRAM region and the Z80 BRAM.
- **Frames from the SDRAM path compared against the MAME oracle directly**,
  not only against the reference sim. MS1-57 hid for weeks because the gates
  ran the one path that did not execute the bug.
- Main-CPU `romwait` < 1 % per frame; sprite pass ≤ 60 % of budget with 0
  late swaps.
- Savestate round trip pixel-exact after frame 0.
- **In `ms1_snd`: save/restore at a frame with YM traffic, and the writes over
  the next 30 frames within 5 % of the pre-save rate**, for every forced
  divider phase.
- YM shadow census > 1 register at any save taken after the music starts
  (MS1-62's signature was 1/256).

### M4 — Quartus and board

1. `quartus_map` first, as a RAM-inference probe: every array a real M10K, no
   duplicates (MS1-37), no multi-driver restores (MS1-38).
2. Fit and timing. Multicycle constraints only where measured (MS1-43), and
   the flags byte not fanned out as data (MS1-44). `build.sh` checks "Full
   Compilation was successful" and removes the stale `.rbf` first.

**Gates**:
- No ROM/PROM data in the bitstream (§2.11 script).
- Timing met, worst path named.
- Boots to attract on both `.mra` files.
- Native screenshots byte-identical to the reference sim for static scenes,
  and a sprite frame pixel-identical (the byte-order check).
- **No strip at the left edge** (MS1-59 re-measured).
- Audio correlation ≥ 0.95 over 60 s against MAME, plus a listening check of
  music tempo (Q2).
- Coin, start and play on keyboard **and** gamepad; service key does what Q15
  says.
- M10K and ALM figures recorded in `hw-bringup.md`.

### M5 — Feature parity and release

Every OSD feature exercised on the board by its **effect**, through the
`.CFG`/`.dip` harness rather than blind menu navigation (MS1-18: a green gate
can mean the feature was never exercised):
- Orientation (on HDMI, which the native screenshot cannot show).
- Flip screen, alone and composed with the DIP.
- CRT Adjust options.
- Pause, with sound held and resumed.
- High scores: set a score, power cycle, confirm restore; the `.nvm` patch
  test.
- Each cheat slot against MAME-comparable behaviour.
- Autofire rates from the `autofire_releases/` copy, including the `.dip`
  override caveat.
- **Savestates: save, reload the core, load, with sound checked**, in the
  attract and in play, all four slots.
- Service key.

Release:
- README with goals, status, supported sets, and attribution for Luca Elia
  and David Haywood, Jotego (jt12/jt03), the T80 lineage (Daniel Wallner,
  MikeJ, Sorgelig), Jorge Cwik (fx68k), Alan Steremberg and Jim Gregory
  (hiscore), Umberto Parisi / rmonic79 (CRT Adjust), and Sorgelig (sdram).
- `docs/known-issues.md` as `MS1Z-n`; `docs/hw-bringup.md`; a tracked
  `.rbf`; a checkpoint doc and tag.
- Push to `kuzearcade/Arcade-JalecoMS1Z_MiSTer`.
- Add the core to kuzecores, re-run its workflow, and verify the files land
  there.

---

## 4. Lessons carried in, mapped onto this board

Each one was paid for already. The reference is where the evidence lives.

### 4.A ROMs, `.mra`, ioctl
- `ROM_LOAD16_BYTE` interleave order is a byte-swap trap (MS1-49).
- The extractor must not drop `BAD_DUMP` parts (MS1-3). Names changed in
  0.289 (MS1-7).
- MiSTer never sends an empty `<switches>` (MS1-47). The core must not run on
  defaults before the switches arrive (MS1-53).
- A saved `config/dips/<mra name>.dip` overrides the whole switches value,
  flags byte included, so the autofire unlock is invisible until it is
  deleted. `autofire_releases/` shares `.mra` names with `releases/`, so the
  two trees collide.
- Regenerating `.mra` files after deleting a tree loses the hiscore and cheat
  blocks unless `carry_over()` has a source. Checksum before and after
  (MS1BCD session, 2026-09-23).

### 4.B SDRAM, caches, buses
- Caches see a **held** address when the CPU is not selecting ROM (MS1-50,
  SS-12 #2).
- Every port needs an arbiter; caches hold their request (SS-12 #3).
- `ioctl_wait` backpressure; the download request is held until the write
  completes; caches stay in reset through the download (SS-12 #4, #5).
- A `valid` held for several clocks passes a per-clock sanity check it should
  fail (MS1-27).

### 4.C Quartus
- Arrays must infer as M10K (MS1-37).
- Restores go inside the owning always block. Verilator accepts the
  alternative silently and Quartus refuses it (MS1-34, MS1-38).
- Quartus appends `.qip` sources to the `.qsf`; revert that before
  committing.
- The build script must refuse to report success without "Full Compilation
  was successful" and a fresh `.rbf`.

### 4.D Video
- Test the SDRAM (LOOKAHEAD) path against the oracle directly (MS1-57).
- Align `hcount`/`vcount` to the RGB pipeline latency (MS1-59).
- The sprite pass must finish before the beam reaches the plane; clear behind
  the display read (MS1-60).
- Flip is rot180 of the finished frame (MS1-13).
- MAME's sprite comment and code disagree; mirror the code and record it
  (MS1-16).
- The oracle's registers and sprites lag its VRAM (MS1-11). One snapshot per
  frame cannot reproduce every frame (MS1-12). Mid-frame palette writes tear
  on the core (SS-11).

### 4.E Audio
- Judge each source isolated, never the mix (SS-10, M2 gate 4).
- `-wavwrite` with `-sound none` writes a silent WAV with no warning (SS-10).
- MAME needs `SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy` (MS1-14). Never
  pipe MAME's stdout, which hides its errors.
- jt03: write stretch, and a live read address (NMK16).
- The Z80 read mux must qualify memory selects (NMK-14).
- Savestate: capture from the live bus; never freeze the replay's clock;
  release the chip when the replay window closes (MS1-62, MS1-61).
- `screen_flag[4]` resets **only the Z80** on this board (§1.5; contrast
  MS1-30).

### 4.F Simulation harnesses
- The Makefile must depend on everything `-y` pulls in (MS1-58). A correct
  fix whose binary did not rebuild looks exactly like a wrong diagnosis.
- A harness that stops building or running must say so (MS1-45).
- Park on the vblank edge like the engine does, and force the phase of every
  held divider (MS1-61).
- **A sound bug needs the sound harness.** The full-board harness may never
  start the sound CPU at the frames it reaches (MS1-62: 64street made zero YM
  writes by frame 200 there).
- Use `stdbuf -oL` on long runs, or progress lines never reach the log.

### 4.G Board and process
- Deploy by md5, not by filename. Reload the core before judging a fix.
- States saved before a savestate-format fix are not recoverable; say so in
  the release notes.
- Keep the scratch tools (`mr`, `mrcp`, `build.sh`, `mk_testset.py`)
  committed under `tools/board/`, without the root password in the files.

### 4.H Working method
- Every claim is a measurement. Report non-blank pixel counts beside a
  pixel-exact result.
- State corrections plainly when a measurement overturns a claim, and do not
  retract a diagnosis on a harness that cannot see the bug (MS1-61).

---

## 5. Risk register

| # | risk | likelihood | impact | mitigation |
|---|---|---|---|---|
| R1 | The real board wires the latch to Z80 NMI; MAME polls | medium | sound timing differs; park/NMI collision | Q1 disassembly in M0; follow MAME for oracle equality, log MS1Z-n if hardware differs |
| R2 | Z80 3 MHz / YM2203 1.5 MHz are MAME guesses ("???", 5 MHz OSC unexplained) | medium | wrong music tempo on hardware, invisible to every MAME gate | follow MAME; compare tempo against a PCB recording if one is found (Q2) |
| R3 | The PROMs are a priority PROM that changes the fixed order | low-medium | sprite/layer order wrong in some scenes on hardware | decode in M0 (Q3); keep `ms1_prio.sv` available |
| R4 | 256- vs 278-line raster shifts IRQ timing | certain (as a difference) | bus traces diverge; a vblank-length-sensitive routine behaves differently | sim-only 256-line parameter for gates; ship 278 (fact 5, Q4) |
| R5 | ~~MAME's `prio_transpen` quirk~~ -- no such quirk (MS1Z-7) | closed | -- | -- |
| R6 | Sprite latency: MAME 0 frames, hardware unknown | medium | sprites a frame off the background in motion | mirror MAME; one-parameter change to 1 or 2 stages |
| R7 | The Z80 program reads above `0x3FFF` | low | unmapped reads differ | Q7 via a MAME tap; SDRAM copy of the full 64 KB stays |
| R8 | hiscore share-relative addresses mis-translated | high if unhandled | scores written into ROM space / never saved | generator fix + M5 power-cycle test |
| R9 | Cheat engine cannot express two of the seven cheats | certain | missing cheats | extend `cheats.sv` (3 acts, masked RMW) |
| R10 | jt03 FM/SSG balance and boot FM burst vs MAME (SS-10) | medium | audio gate fails on level/envelope | isolate halves from day one; start from Sand Scorpion's measured mix |
| R11 | jt03 unconnected I/O ports read differently from MAME | low | a driver that reads them branches differently | Q11 |
| R12 | Object RAM absent → boot RAM test fails | low (it is planned as RAM) | no boot | §2.4 item 6; Q12 |
| R13 | Z80 reset copied from MS1-30 resets the YM2203 too | medium | a note or timer state lost that MAME keeps | §1.5; explicit test in M2 |
| R14 | YM2203 prescaler registers skipped in the replay restore the wrong divider | medium | wrong pitch or tempo after a load | Q14; replay order proven in `ms1_snd` |
| R15 | ROMs unavailable | blocking | nothing can be gated | user supplies the zips (prerequisite) |
| R16 | Shared `rtl/jaleco/` files regress MS1BCD | medium | MS1BCD breaks on a Z change | `BOARD_Z = 0` gate re-run on every shared-file change |

---

## 6. Open questions — each settled by a measurement

- **Q1 Latch → NMI?** Disassemble `lom_01.rom` at `0x0000`, `0x0038`,
  `0x0066`, and every `LD A,(E000h)`. Answer with addresses and bytes: a real
  NMI handler that reads the latch, or a poll loop.
- **Q2 Sound clocks.** MAME's values are marked `???`. Any PCB recording's
  music tempo against the core's, beat for beat.
- **Q3 What the PROMs are.** Run MAME's `priority_create()` conversion on the
  512 bytes. Does it yield `0x0314f`-like orders, and does anything depend on
  sprite colour bit 3?
- **Q4 Raster.** 278 lines (MS1 family) or 256 (MAME's guess)? Find a
  measurement: PCB video frame timing, or hsync frequency from a board
  photo/manual. Until then ship 278 and gate with both.
- **Q5 Sprite order on hardware** (MAME settled by MS1Z-7).** Look for a PCB video frame
  with two sprites crossing a layer-1 edge.
- **Q6 Sprite latency on hardware.** The same source as Q5, in motion.
- **Q7 Z80 address range used.** A MAME Lua read tap on `0x4000-0xBFFF` and
  `0xC800-0xDFFF` over attract + play. Expect zero hits.
- **Q8 Button roles.** Which of Button 1 / Button 2 is attack and which is
  jump, for the `.mra` `<buttons>` names. From play.
- **Q9 Cabinet DIP.** Does "Cocktail" do anything in MAME's type Z (no
  cocktail input mux)? Test in MAME.
- **Q10 Demo sounds and service.** What SYSTEM b5 (Service 1) does in
  `lomakai`. Coin? Test menu with F3?
- **Q11 YM2203 port A/B read value** in MAME with no callbacks, and whether
  the Z80 program ever reads them.
- **Q12 Object RAM use.** A MAME tap on `08C000-08FFFF` over boot and attract:
  RAM test only, or real use?
- **Q13 Unmapped read values** on both CPUs in MAME, from the debugger, for
  the unmapped ranges the programs touch.
- **Q14 YM2203 prescaler registers.** Does the driver write `0x2D-0x2F`, and
  which divider does it leave selected? From the sound trace.
- **Q15 Service key.** Where F2 should go, once Q10 is known.

---

## 7. Day one

1. Get `lomakai.zip` and `makaiden.zip`; verify CRCs.
2. Q1, Q3, Q7 offline. Each is an hour of disassembly or Python, and each can
   change the design of the parts that are hardest to change later: the Z80
   park, the priority stage, and the Z80 ROM placement.
3. `git init`, `deps.lock`, `bootstrap.sh`, copy the verbatim set, and run
   NMK16's `ss_z80` and MS1BCD's `tilemap_test` here.
4. MAME captures for `lomakai`: attract frames, bus trace, sound trace.
5. Start M1 with `ms1_sprites.sv`'s `BOARD_Z` path. It is the one genuinely
   new piece of video (see MS1Z-7 for how its order was settled), and the one place where "matches
   MAME" and "matches hardware" may already disagree.

---

## Appendix A — OSD string (draft)

    "JalecoMS1Z;SS3E000000:80000;",
    "-;",
    "HBO[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "HBO[3:1],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "H0O[9:8],Orientation,Horz,Vert 90,Vert 270;",
    "O[17],Flip screen,Off,On;",
    "P3,CRT Adjust;",
    "P3O[101],CRT Adjust,Off,On;",
    ... (P3 H-Size / H-Position / V-Shift / V-Size / V-Size Mode, verbatim from MS1BCD)
    "h1O[12:10],P1 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
    "h1O[15:13],P2 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
    "-;",
    "DIP;",
    "-;",
    "O[29],Pause,Off,On;",
    "P1,Scores;",
    "P1O[39],High Scores,Off,On;",
    "P1-;",
    "dAP1R[30],Save Scores;",
    "dAP1R[31],Reset Scores;",
    "P2,Cheats;",
    "P2-;",
    "h3P2O[32],Infinite Lives,Off,On;",
    "h4P2O[33],Infinite Energy,Off,On;",
    "h5P2O[34],Infinite Time,Off,On;",
    "h6P2O[35],Infinite Money,Off,On;",
    "h7P2O[36],Infinite Jumps,Off,On;",
    "h8P2O[37],Invincibility,Off,On;",
    "h9P2O[38],Always Have All Keys,Off,On;",
    "P4,Savestates;",
    "P4O[41:40],Slot,1,2,3,4;",
    "P4-;",
    "P4R[42],Save state (Alt+F1 F5 F3 F4);",
    "P4R[43],Load state (F1 F5 F3 F4);",
    "-;",
    "R[0],Reset;",
    "J1,Button 1,Button 2,Button 3,Start,Coin;",
    "I,", ... (MS1BCD's savestate info messages, verbatim)
    "V,v",`BUILD_DATE

Status bit assignments are MS1BCD's, so `board_feature_test.py` and the
`.CFG` harness carry over without renumbering. `status_menumask` keeps
MS1BCD's layout.

## Appendix B — Savestate image map (draft, 16-bit words)

| word range | contents | size |
|---|---|---:|
| `0x00000-0x07FFF` | main work RAM | 32768 |
| `0x08000-0x09FFF` | layer 0 VRAM | 8192 |
| `0x0A000-0x0BFFF` | layer 1 VRAM | 8192 |
| `0x0C000-0x0CFFF` | Object RAM | 4096 |
| `0x0D000-0x0D3FF` | palette | 1024 |
| ~~`0x0D400-0x0D7FF`~~ | ~~sprite snapshot buffer~~ (removed with MS1Z-12: the line renderer holds no state across a line, so it is rebuilt from work RAM) | -- |
| `0x0E000-0x0E3FF` | Z80 RAM (byte pairs) | 1024 |
| `0x0E400-0x0E4FF` | YM2203 shadow | 256 |
| `0x0E500-0x0E53F` | scalars: scroll x/y/ctrl x2, `screen_flag`, latch, IRQ holds, phi/Z80/YM divider phases, write-stretch state, YM select | ≤ 64 |
| `0x0E540-0x0E547` | 68000 park SSP/USP, Z80 park SP/IM | 8 |
| `0x10000-0x1FFFF` | sprite plane (if saved, as MS1BCD does) | 65536 |

About `0x20000` words (256 KB), inside the `0x80000`-byte slot. Every region
passes the loopback test (stream out, stream in, stream out, compare) before
any round-trip gate. That test separates "the image is incomplete" from "the
image is not written where it is read".

## Appendix C — M10K budget (estimate; the `quartus_map` probe decides)

| item | M10K (est.) |
|---|---:|
| main work RAM 64 KB, 2 ports | ~64 |
| Object RAM 8 KB | ~8 |
| VRAM 2 x 16 KB | ~32 |
| palette 2 KB | ~2 |
| sprite snapshot 2 KB | ~2 |
| sprite plane, 9 bits x 64K, two read copies (MS1BCD figure) | ~144 |
| Z80 ROM window 16 KB | ~16 |
| Z80 RAM 2 KB, YM shadow | ~3 |
| PROM 512 B | ~1 |
| jt03 internals | ~6-10 |
| hiscore, cheats, savestate buffers | ~15-20 |
| video_retime, crt_adjust line buffers, scaler/`sys/` | ~100-120 |
| caches (main, tiles, sprites) | ~30-40 |
| **total** | **~420-470 of 553** |

MS1BCD's 544 includes the sound 68000's 64 KB, a third VRAM, the TMP91640's
ROM and RAM, two OKI caches and jt51. Removing those is what makes room for
the Z80 window in BRAM, and for a 10-bit sprite plane if Q3 or Q5 ever needs
one.
