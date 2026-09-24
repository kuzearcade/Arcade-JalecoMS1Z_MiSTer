# Known issues and findings — Arcade-JalecoMS1Z_MiSTer

Numbered `MS1Z-n`. As in the sibling cores, an entry is closed by a
measurement, never by reasoning, and the measurement is written down.

---

## MS1Z-1 — The sound board, read from the ROM (closed)

`docs/PLAN.md` questions Q1, Q7, Q11 and Q14, answered from `lom_01.rom`
(MAME's `unidasm -arch z80`) before any sound RTL was written.

- **The latch is polled, not wired to NMI.** The Z80 runs `IM 1`; its YM2203
  timer handler is at `0x0038`, and `0x0066` is the *middle* of that handler
  (`rst $28`). An NMI would land mid-routine, so the board cannot be raising
  one on a latch write. The command is read at `0x0113`
  (`ld a,($E000)`, `0xFF` = none), from the timer interrupt. MAME's
  `set_input_line(5, HOLD_LINE)` on the Z80 does nothing (`z80.h`: lines 0-2;
  `execute_set_input`'s `default: break`), which agrees.
  **Consequence:** `ss_z80_park` owns NMI and the overlay at `0x0066` without
  colliding with the game.
- **16 KB is the whole program.** Every byte of `lom_01.rom` above `0x3E30` is
  `0xFF`; MAME maps only `0000-3FFF`. The window lives in block RAM.
- **The I/O ports are never read.** Both `in a,(1)` (`0x084A`, `0x08C6`) are a
  read-modify-write of SSG register 7, the mixer enable. Register 7 has to
  read back what was written, which the savestate replay provides.
- **The prescaler is selected by a bare address write.** Reset code at
  `0x001B` writes `0x2F` to port 0 with no data write: YM2203 prescaler /2.
  jt03 implements it (`jt12_mmr.v:279-281`). A register shadow cannot see an
  address-only write, so `ms1z_sound.sv` tracks the prescaler beside the
  shadow and the replay re-issues it first.

## MS1Z-2 — The two PROMs are not a priority PROM (closed)

MAME's own `priority_create()`, run over `makaiden.9` + `makaiden.10` as a
512-byte B/C-format PROM, fails for all sixteen priority codes (`0x3ffff` or
`0xfffff`). `.10` is `0x0F` everywhere except two contiguous runs
(`0x6D-0x87` = 9, `0xF8-0xFA` = 10, `0xFB-0xFF` = 9, and `0xDF` = 7); `.9` is
`3` except `2` at every index `x1` and `0`/`7` at `0x01`/`0xF7` -- the shape
of counter-indexed timing or decode PROMs. The fixed order MAME uses
(`pri = 0x0314f`) stands; the PROMs travel in the `.mra` (index 1) and the
core drops them. What they actually decode is still unknown.

## MS1Z-3 — The Object RAM window is never referenced (closed, static)

No `0x0008Cxxx` / `0x0008Exxx` long literal occurs anywhere in `lom_30` +
`lom_20`; the reset code clears work RAM (`0x0F0000`, 16 K longs) and
nothing else. The window is still RAM in the core, because MAME maps it.
A dynamic tap over a full attract + play would make this a stronger claim.

## MS1Z-4 — MAME 0.289's Lua has no `screen:vpos()`, and taps swallow errors (closed here; affects MS1BCD)

`luaengine.cpp` binds no `vpos` on `screen_device`. Calling it raises an
error, and **an error inside a memory write tap is swallowed**: the tap just
stops at that line. MS1BCD's `sim/oracle/ms1_capture.lua` computes its
`midframe_writes` counter this way, *after* updating the register shadow --
so the shadow was right and the counter has been **0 in every MS1BCD
capture**. `ms1_capture.lua` here derives the scanline from
`time_until_vblank_start()` instead.

Separately: a write tap over the 0x800-byte Sprite Data sub-range of work
RAM (`0x0F8000-0x0F87FF`) never fired at all; one over the whole work-RAM
handler, filtered in Lua, does.

## MS1Z-5 — MAME's picture pairs one frame's composition with the next frame's palette (closed as a finding)

Measured, then explained from MAME's source:

- `frame_done` fires at raster line 240 (measured: `vpos` 240, 256 lines to
  the next vblank), and the state dumped there is what frame F is drawn
  from. The game's own scroll writes land at line 241 (measured), for F+1.
- **But `screen:pixels()` at `frame_done(F)` returns the PREVIOUS bitmap.**
  `screen.cpp`'s `video_output_update` swaps the screen's two bitmaps at
  vblank, before the callback. And `pixels()` colours that bitmap through
  the palette **as it stands at that moment**.
- So MAME's picture F+1 = composition from state F, coloured by palette F+1.

Evidence: the video block against MAME's demo frames, state F vs picture
F+1: **220 / 220 pixel-exact** only when the palette comes from state F+1;
with state F's palette every third frame fails by 1,468 pixels (the
waterfall's palette cycle), and against picture F the layers are one scroll
step (2 px) out.

This is why the full-board comparison aligns at k = +1, and why lomakai's
title logo -- a palette cycle with period 4 -- differs from MAME on
alternate frames while every tilemap pixel matches: the core colours each
pixel with the palette at the moment the beam draws it, as a raster board
does. `ms1z_core` exports `dbg_pal_idx` and the frames harness dumps indices
(`MS1_IDX=1`) so a full-board frame can be recoloured through MAME's palette
F+1 for an exact comparison.

## MS1Z-6 — Quartus 17 silently does not infer RAM from byte-lane writes (closed)

The first compile had **107,954 registers** (MS1BCD: 36,808): the palette and
the Object RAM were flip-flops. Two causes, neither reported as "uninferred":

1. `mem[a][15:8] <= ..; mem[a][7:0] <= ..` lane writes are not recognised as
   byte enables here -- in a shared always block or in one of their own.
2. MS1BCD keeps two identical palette copies (one per reader). With byte
   writes the synthesiser merged them into ONE array with two reads and a
   byte-enabled write, which no M10K mode serves.

Fix: the palette is one array in true-dual-port form, and byte writes on the
palette and Object RAM work like the VRAM's -- the write waits one clock
into the bus cycle, when the port's own registered read holds that address's
word, and the other lane is merged from it. Every write is a full word.
**25,987 registers**; fit: 19,192 / 41,910 ALMs, 399 / 553 M10K, timing met.

## MS1Z-7 — Type-Z sprites: the HIGHEST index is in front (closed)

`docs/PLAN.md` 1.6 read `draw_sprites`'s 127→0 loop through `prio_transpen`
as a painter's order (lowest index in front) with a "sprites show through
layer 1 where two overlap" quirk, and called the driver's header comment
("From last in Sprite RAM (frontmost) to first") wrong. **The plan was wrong
and the comment right.** `prio_transpen` ORs bit 31 into the priority mask
("high bit of the mask is implicitly on", `drawgfx.cpp`) and every opaque
source pixel sets the priority byte to 31, drawn or not -- so the first
sprite to reach a pixel keeps it, and one hidden under layer 1 hides what is
behind it. Found on the demo as the player's shield (entry 58) drawn behind
the player (entries 50-57) where MAME has it in front.

Now: walk 127 → 0, first writer wins, sprites under opaque layer 1.
**220 / 220 demo frames pixel-exact** (39,143-45,850 non-blank pixels each).

## MS1Z-8 — The sprite plane powered up opaque (closed; shared with MS1BCD)

`plane_e`/`plane_d` started at zero: pen 0, which is opaque. The row-at-a-time
clear (MS1-60) sweeps a row only after the display has read it, so the first
displayed frame after power-up is a solid sprite colour, and a pass that runs
before a row has been swept finds every pixel taken. Fixed by storing the pen
nibble inverted at the RAM boundary, so the RAM's power-up zero reads as pen
15 (an `initial` fill was tried first; Quartus 17 refuses a 65,536-iteration
loop). `rtl/jaleco/ms1_sprites.sv`
is shared text, so MS1BCD's copy has the same power-up frame.

## MS1Z-9 — MS1BCD's savestate never saves the sprite engine's state (open, MS1BCD)

Found while deriving `ms1z_core.sv`. `ms1_sprites.sv` serves its FSM state at
image words `0x1D060-0x1D07F` through `ss_spr_rdata`, but `ms1bcd_core.sv`'s
readback routes only `ss_addr[19:16] == 2` (the plane) to it; `0x1D06x`
falls through to `ms1_main`, which returns 0. The restore path writes those
zeros back, so a load resets the engine to idle. Saves happen at vblank --
exactly when the pass runs. `ms1z_core.sv` routes the range. Not fixed in
MS1BCD by this project.

## MS1Z-10 — The first 18 frames after reset differ from MAME (open)

Core frames 0-17 against MAME's pictures 1-18:

| frames | core | MAME picture |
|---|---|---|
| 0-4 | black | solid white |
| 5-17 | the boot's tile patterns on both layers (6-13 colours) | black |
| 18 on | identical (the title) | identical |

MAME's OWN state dumps say those frames should not be black: from frame 5 on
its palette holds 667 non-zero entries and both layers' VRAM is full, which
is exactly what the core is drawing. So MAME is not presenting a picture of
the state it holds during boot -- most likely a screen update that does not
happen, leaving `pixels()` on a stale bitmap (MS1Z-5 describes that path).
Not investigated further: nothing after frame 17 depends on it, and the
board's own first seconds cannot be compared with MAME frame for frame
anyway.

## MS1Z-11 — Legend of Makai's two raster splits need per-slice state to compare in the oracle (note)

The IRQ 1 / IRQ 3 handler (`0x42C`) reloads layer 1's scroll from RAM when a
flag is set, so demo frames carry register writes at lines 16 and 97
(`midframe_last` in the capture). They did not stop the whole-frame match
(MS1Z-7), but a frame that changes state between slices would need the
slices captured separately (MS1-12's class).

## MS1Z-12 — Sprites are one frame older than the background, against MAME (open, design decision)

Whole-board simulation against MAME's attract demo (frames 1940-2159,
recoloured through MAME's palette per MS1Z-5): the layers match MAME's picture
at offset k = +1; the SPRITES match MAME's picture at k = 0. In one frame
(2141) every one of the 1,581 differing pixels is a sprite pixel or the
background a sprite should have covered; at k = 0 the sprite palette group
differs in 0 pixels. The video block itself is exact (220/220, MS1Z-7), so
this is purely WHEN the sprite list is read.

Why: lomakai rewrites its Sprite Data during the FIRST ~100 lines of each
frame (measured with the capture's tap: writes cluster at MAME lines 0-100,
a few at 160-190). MAME's type Z draws sprites from live RAM at render time
-- slices at the mid-frame scroll write (line 97) and at line 240 -- so a
frame shows the list written during that same frame. The core, like MS1BCD,
snapshots Sprite Data once at vblank and renders a whole-frame plane before
the display reaches it, so the list written during frame N can only appear
in frame N+1.

Visible consequence: while the screen scrolls, sprites are drawn one scroll
step behind the background (the player and the log platforms in frame 2141
are offset by one frame of motion). The real board's sprite hardware is not
documented; MAME's model, and the game writing its list mid-frame, both
point to hardware that reads the list close to when each line is drawn.

Options:
1. A LINE renderer for type Z: during each raster line, walk the 128
   entries in live Sprite Data and draw the ones on the next line into a
   line buffer. That reproduces MAME's slices wherever the list is stable
   within a slice. Budget: 3,072 clocks a line, ~512 to scan, ~32 per sprite
   drawn -> ~80 sprites per line. A new block, not shared with MS1BCD.
2. Two plane passes per frame (a late one for the rows below the game's
   update, the vblank one for the rows above). Keeps the shared engine;
   matches MAME only below the late snapshot line.
3. Leave it: one frame of sprite lag during scrolling.
