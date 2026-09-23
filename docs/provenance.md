# Provenance

Every file this core did not start from scratch, where it came from, and how
far it has moved. Source commits at the time of the copy (2026-09-23):
Arcade-JalecoMS1BCD_MiSTer `f858ada`, Arcade-NMK16_MiSTer `7d84cb9`,
Arcade-SandScrp_MiSTer `b09d359`.

- **verbatim**: byte-identical to the source; a later change is a deliberate
  fork and gets a line here.
- **shared**: the same text as MS1BCD's copy, with MS1-Z behaviour behind a
  compile-time parameter whose default reproduces MS1BCD exactly, so a fix
  can be ported as a patch in either direction.
- **derived**: a new file built from the source's structure.

## RTL

| file | from | status |
|---|---|---|
| `rtl/jaleco/ms1_tilemap.sv` | MS1BCD | shared: `ROM_MASK` (tile-code wrap on small ROMs) |
| `rtl/jaleco/ms1_sprites.sv` | MS1BCD | shared: `BOARD_Z` (direct Sprite Data walk, the `cov2` plane bit), `TILE_MASK` |
| `rtl/jaleco/ms1_video.sv` | MS1BCD | shared: `BOARD_Z` (fixed order, palette groups), per-layer ROM masks |
| `rtl/jaleco/ms1_prio.sv` | MS1BCD | verbatim (instantiated only when `BOARD_Z = 0`) |
| `rtl/ms1z/ms1z_main.sv` | MS1BCD `rtl/ms1bcd/ms1_main.sv` | derived |
| `rtl/ms1z/ms1z_core.sv` | MS1BCD `rtl/ms1bcd/ms1bcd_core.sv` | derived |
| `rtl/ms1z/ms1z_rom_hw.sv` | MS1BCD `rtl/ms1bcd/ms1bcd_rom_hw.sv` | derived |
| `rtl/ms1z/ms1z_sound.sv` | SandScrp `sandscrp_core.sv` Z80/jt03 block, NMK16 `tdragon2_core.sv` | derived; MS1-61/62 rules designed in |
| `MS1Z.sv` | MS1BCD `MS1BCD.sv` | derived; the hps_io/reset, hiscore/cheat/savestate and video-chain blocks are spliced verbatim |
| `rtl/cheats.sv` | MS1BCD | forked: `ACTS` 3, masked-byte action kind, `ram_dout` input |
| `rtl/savestate/*.sv` | MS1BCD (`ss_z80_park.sv` originally NMK16) | verbatim |
| `rtl/sdram*.sv`, `rtl/rom_cache*.sv`, `rtl/tile_prefetch_byte.sv`, `rtl/video_retime.sv`, `rtl/crt_chain.sv`, `rtl/pll*.v` | MS1BCD | verbatim |
| `rtl/third_party/{fx68k,hiscore,crt_adjust}` | MS1BCD (tracked, modified hiscore and crt_vsize) | verbatim |
| `rtl/third_party/{jt12,t80}`, `rtl/third_party_gen/t80/` | SandScrp (same pins as NMK16) | verbatim |
| `sys/` | MS1BCD | verbatim |

## Tools and simulation

| file | from | status |
|---|---|---|
| `tools/gen_ms1z_mra.py` | MS1BCD `gen_ms1bcd_mra.py` | derived (same XML escaping, FAT names, alternatives, carry-over, map rule) |
| `tools/ms1z_romdata.py` | new | the one ROM table |
| `tools/mk_ms1z_images.py`, `tools/z_frame_compare.py` | new | |
| `tools/gen_hiscore_mra.py` | MS1BCD | forked: `:ram/share` records |
| `tools/gen_cheats_mra.py` | MS1BCD | forked: Makai slot names, 3 actions, masked kind |
| `tools/gen_autofire_mra.py` | MS1BCD | forked: `INCLUDED` |
| `sim/oracle/ms1_capture.lua` | MS1BCD | forked: type-Z map, `MS1_SPRTAP`, the `vpos` fix (MS1Z-4) |
| `sim/rtl/ms1z_frames/` | MS1BCD `sim/rtl/ms1_frames` | derived |
| everything else under `tools/` | MS1BCD | verbatim, some not yet adapted (B/C/D-specific) |
