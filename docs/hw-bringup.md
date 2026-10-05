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
Scores save/restore across a power cycle, Orientation (HDMI path),
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


## 2026-10-05 — Autofire removed, buttons Attack/Jump (v2026-10-05, issue #1)

`Arcade-JalecoMS1Z_20261005.rbf` md5 `29ea32a851839d76b379f8690fab5beb`
(251 / 553 M10K, timing met), deployed with both new `.mra` files, each
checked by md5. The 20260923 bitstream was moved to `/media/fat/rbf_backup/`
so the loader cannot pick it. Keys through `mister_keys.py`.

| test | result |
|---|---|
| load from `Legend of Makai (World).mra` | title at 30 s, attract demo at 45 s |
| coin (5) + start (1) | game starts, timer 2:59 counting down |
| Left Alt (Jump, Button 2) tap | player in the air 1 s after the press |
| Left Ctrl (Attack, Button 1) tap | attack pose, 316 pixels of the player box differ from idle |
| Left Ctrl held 2.5 s | one swing, back to the idle pose at 1.8 s: no repeat, so no autofire |
| Space, Q (the old Button 3 keys) held | player box identical to idle, 0 pixels differ |
| savestate: Alt+F1 at 2:53, run 21 s (2:32), F1 | `Legend of Makai (World)_1.ss` 393,224 bytes; 4 s after the load the timer reads 2:48, 8 s on 2:38 |
| cheat Infinite Time (status bit 34, via `lomakai.CFG`) | demo timer holds 9:58 over 10 s; without the cheat 4:00 to 3:49 over the same 10 s. Status bits unshifted by the autofire removal |

Not checked: a real gamepad's default mapping (`A,B,-,Start,R`) -- MiSTer
applies it only to a pad with no saved mapping, and the virtual keyboard
cannot show it.

## 2026-10-05 — sound across a savestate load

Same bitstream (`29ea32a8...`). Audio recorded from the board's HDMI output
through the capture box (`arecord -D hw:1,0`, 48 kHz; L = R, the YM2203 is
mono), 70 s from 6 s into a game with no input: Alt+F1 at ~6.5 s, F1 at ~31.5 s.

| check | result |
|---|---|
| silence anywhere in the 70 s | none: lowest 0.25 s RMS 748 (a quiet note in the tune), lowest 10 ms RMS around the load 702 |
| click at the load | none: largest sample step in 29-35 s is 1773, against 3436 elsewhere in the take |
| does the sound come back to the save point | yes. Up to 31.87 s the take matches itself 25.172 s earlier in 0 of 132 50 ms windows; from 31.92 s every window does (corr 0.94-0.995), i.e. at 31.9 s the music jumps back to what played at 6.75 s and replays it sample for sample |
| how long the replay stays exact | to 42 s (10 s, corr >= 0.997); 44-56 s it holds at corr 0.92-0.999 with the lag moved 10-20 ms, about one frame, which is the tempo still right but the note timing a frame off the original run |

So the Z80 and YM2203 state is saved and restored, and the music plays on
through a load without a dropout.

## 2026-10-05 — high scores (v2026-10-05.2, MS1Z-14, MS1Z-15)

`Arcade-JalecoMS1Z_20261005.rbf` md5 `faa25c76c664814ee5172081024c39ff`
(19,500 ALMs, 252 / 553 M10K, timing met, worst slack +0.224 ns), replacing
the earlier build of the same name, with both `.mra` files (START_WAIT
0x01400000), each checked by md5. High Scores set through `lomakai.CFG`
(status bit 39), the OSD opened with F12 to save.

| test | v2026-10-05 | v2026-10-05.2 |
|---|---|---|
| fresh save | MAME's table | MAME's table |
| names edited to `CLD` / `XYZ`, reload, save again | `C\0D`, `A\0I`, `X\0Z`: every high-lane byte 0 | `CLD`, `AKI`, `XYZ`, area bytes intact, three reloads in a row |
| table's last byte 00 -> 50, reload | -- | kept; HUD shows `HI 30050` in the demo and in play |
| first high-score screen after a reload | defaults | `CLD` / `XYZ` (21-27 s) |
| savestate: Alt+F1 at 2:53, 21 s on (2:32), F1 | -- | 2:48 4 s after the load, 2:38 8 s later |
| cheat Infinite Time | -- | holds 9:58 over 10 s; without it 4:00 to 3:49 |
