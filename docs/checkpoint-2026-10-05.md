# Checkpoint — 2026-10-05

Where the core stands after one day of release work (2026-10-05, `c422cb1` to
`5af2b77`, four commits, releases `v2026-10-05` and `v2026-10-05.2`). This is
a snapshot, not a plan: see `docs/PLAN.md` for the milestones,
`docs/known-issues.md` for every defect and `docs/hw-bringup.md` for the
board measurements behind each line below.

## What runs

**Both sets, Legend of Makai (World) and Makai Densetsu (Japan), on a
DE10-Nano** from one bitstream, published through the kuzecores downloader
database (pin `5af2b77`, kuzecores `fd34914`).

Latest bitstream `Arcade-JalecoMS1Z_20261005.rbf`, md5
`faa25c76c664814ee5172081024c39ff`, 3,421,604 bytes: **19,500 / 41,910 ALMs
(47 %), 252 / 553 M10K (46 %), 0 timing violations (worst slack
+0.224 ns)**. Unlike MS1BCD (98 % M10K) there is room on this board.

## Changed this session

- **Issue #1 — buttons named Attack and Jump**, from play, as the reporter
  gave them (`Attack,Jump,-,Start,Coin`, defaults `A,B,-,Start,R`). The
  hidden `-` keeps Start and Coin on pad bits 7 and 8, so the input wiring
  did not move. Answers PLAN Q8.
- **Autofire removed.** Legend of Makai is a platform game. Gone with it: the
  OSD entries, the `<switches>` byte 2 unlock, the Button 3 alias and its
  Space/Q keys, `tools/gen_autofire_mra.py` and `autofire_releases/`. Byte 2
  stays in the `.mra`, unread, so saved `.dip` files still match.
- **MS1Z-14 — high scores came back with every even byte zeroed** (MS1BCD's
  MS1-63, carried in with the fork). The back door's byte writes stored whole
  words into 16-bit arrays Quartus inferred without byte enables; work RAM and
  its Sprite Data copy are now byte-lane pairs. `hiscore.v`'s dump check,
  which threw real saves away, is removed. The same path carries cheat pokes,
  which could clear their neighbour byte.
- **MS1Z-15 — the first high-score screen drew the defaults.** The game
  copies its table at frame 32/33; the restore came ~4 s after reset.
  START_WAIT is now 0.437 s, between the frame-17 loop that writes the table
  and the copy.

## What is measured on the board

| feature | result |
|---|---|
| boot, attract, coin, start | title, high-score table, demo; game starts |
| Jump (Left Alt) / Attack (Left Ctrl) | player in the air / attack pose (316 px differ from idle) |
| Attack held | one swing, no repeat |
| Space, Q (old Button 3) | 0 px differ from idle |
| savestate round trip | timer back to the save point, play continues |
| sound across a load | no gap, no click; replays the saved point sample for sample (corr 0.94-0.995) |
| cheat Infinite Time | holds 9:58 over 10 s; without it 4:00 to 3:49 |
| high scores | save as MAME's table; edits restore and stay over three reloads; first table and HUD show them |

## Still open

- `MS1Z-9` — MS1BCD's savestate never saves the sprite engine's state (open
  in MS1BCD; checked here only by the round trips above).
- `MS1Z-10` — the first 18 frames after reset differ from MAME's pictures
  (MAME's presentation, by its own state dumps). MS1Z-15's START_WAIT relies
  on the frames from 18 on matching MAME, which they do.
- `MS1Z-11` — the two raster splits need per-slice state in the oracle (note).
- After a savestate load the music replays exactly for ~10 s, then runs about
  one frame (10-20 ms) off the original take, tempo intact. Not audible in the
  capture; not investigated.
- Not yet checked on the board: a real gamepad's default mapping with the `-`
  placeholder (MiSTer applies it only to a pad with no saved mapping), Pause,
  Orientation (HDMI), CRT Adjust, the makaiden set.
- PLAN questions still open: Q1-Q7 and Q9-Q15.

## Lessons this session paid for

**A fork carries its parent's bugs, including the ones fixed after the
fork.** MS1-63 was fixed in MS1BCD the same morning; this core had both of
its faults. When a sibling closes a defect in shared code, check the forks
the same day.

**A check that passes early can be worse than one that passes late.** The
hiscore module re-checks every ~5 us; MAME's plugin once a frame. With a short
start wait it caught the game half-way through writing its table, and the
restore was written over -- a total loss where the long wait had only been
cosmetic. Measure the game's own boot (Lua write taps in MAME) before choosing
a wait, and put the reasoning next to the number.

**The file round trip is not the whole test.** MS1BCD's MS1-63 sweep compared
the saved file before and after a reload, which proves the restore landed but
not that the game shows it. The first high-score screen is the check a player
sees.

**Cross-correlate a capture against itself to prove a restore.** With no
input between save and load, a full restore replays the earlier audio sample
for sample; the onset of the match times the load to 50 ms.
