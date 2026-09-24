# Local MAME patches

Diagnostic patches for the local MAME tree (`~/mame`, not part of this
repository). Each is env-gated and inert by default: a patched MAME renders
stock output unless the variable is set.

## `megasys1-sound-isolation.patch`

`MS1_SND_ISO` in `src/mame/jaleco/megasys1.cpp`:

| board | `MS1_SND_ISO` | routes |
|---|---|---|
| B/C (MS1BCD) | `fm` / `oki1` / `oki2` | the YM2151 / one OKIM6295 only |
| **Z** (this core) | `fm` | YM2203 FM only (ymfm output 3) |
| **Z** | `ssg` | YM2203 SSG only (outputs 0..2) |

Apply with `cd ~/mame && git apply .../megasys1-sound-isolation.patch`, then
rebuild (`make -j$(nproc)`; only megasys1.cpp recompiles). Run MAME with
`SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy`, `-sound sdl`, never
`-sound none` (a silent `-wavwrite`, SS-10), and never pipe its stdout.
