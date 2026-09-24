# Hardware bring-up — Arcade-JalecoMS1Z_MiSTer

DE10-Nano at 192.168.1.138. Every file deployed is checked by md5 against
the local copy; the core is loaded through `/dev/MiSTer_cmd`, options are set
through `/media/fat/config/lomakai.CFG` (the 128-bit OSD status word) because
the native screenshot has no OSD overlay (tools/board_feature_test.py).

## 2026-09-23 — first bitstream

`JalecoMS1Z.rbf` md5 `617801cadda98340e9b3dd91105e9025`, deployed as
`/media/fat/_Arcade/cores/Arcade-JalecoMS1Z_20260923.rbf`.
Quartus 17.0: 19,179 / 41,910 ALMs (46 %), 26,622 registers,
399 / 553 M10K (72 %), 0 timing violations.

| test | result |
|---|---|
| load from `Legend of Makai (World).mra` | boots; high-score table at 25 s, then the attract demo with sprites, both layers and the HUD |
| savestate: Alt+F1, run 20 s, F1 | `Legend of Makai (World)_1.ss` written (393,224 bytes); the load goes back to the earlier scene and play continues (screenshot 10 s later is in the demo). Sound across the load not verifiable remotely |
| Flip screen (status bit 17) | flipped high-score table = rot180 of the normal one, **0 of 57,344 pixels different** |
| cheat Infinite Time (bit 34, three pokes) | demo timer holds 9:58 instead of counting down from 4:00 |
| cheat Always Have All Keys (bit 38, masked read-modify-write) | the HUD's `KEY=` shows a key where it was empty |

Not yet done on the board: audio (needs ears or a capture), Pause, High
Scores save/restore across a power cycle, Autofire, Orientation (HDMI path),
CRT Adjust, the makaiden set.

## 2026-09-24 — SSG level (MS1Z-13)

`JalecoMS1Z.rbf` md5 `f282959f6bc41e0e97136d2612da45f3` (19,200 ALMs,
399 M10K, timing met), replacing the first build under the same name. The SSG
is weighted x1.5 against the FM, measured against MAME's isolated halves.
Boots to the attract demo. The audio itself has not been listened to on
the board.

## 2026-09-24 — sprite line renderer (MS1Z-12)

`JalecoMS1Z.rbf` md5 `1ae9281289ac842ac39fe5ebc5c0d51c` (19,684 ALMs,
26,874 registers, 251 / 553 M10K, timing met), replacing the previous build
under the same name.

| test | result |
|---|---|
| load, attract | title, then the demo; while the waterfall scrolls, the player and the log platforms sit on the background |
| savestate: Alt+F1 at timer 3:52, run 20 s (back to the title), F1 | 1 s after the load the demo is back at 3:52 with the player and sprites in place; 8 s later it has played on to 3:43 |

