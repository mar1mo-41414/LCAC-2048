# Auto2048 — an auto-play tweak for 2048 on LiveContainer

[日本語 README →](README.md)

A tweak (dylib) that plays the regular mode of **2048** (`com.ketchapp.2048`) on
[LiveContainer](https://github.com/LiveContainer/LiveContainer).
It searches up to eight moves ahead late in a game and picks the next swipe. **Reaching 2048 is not guaranteed.**

- **Automatic moves** — scores legal moves using empty cells, monotonicity, a snake pattern and more.
  Empty cells are scored by count and by whether they are connected to other free space.
  When the two highest tiles can be joined, it always takes that move.
- **Adjustable speed** — long-press the button to cycle through `x1` / `x2` / `x4` / `MAX`.
- **Deeper search** — a per-move node budget, so the search reads 4 to 6 moves ahead.
  Once four or fewer cells are free it widens the budget four times and reads up to eight moves ahead
  (the tree is small there, so this costs very little time).
- **Spawn value forced to 4 (experimental)** — it looks for the game's "chance of a 4" and
  raises it to 1.0. When that does not work it falls back to 2 / 4 on its own
  (see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)).
- **Visible state** — the button shows `THINK` / `STALE` / `PAUSE` and so on.
  What each one means: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) (Japanese).
- Targets the regular 4×4 game in 2048 **4.0.8** only. Challenge and multiplayer modes are not supported.

## Status

| Item | State |
| --- | --- |
| Real device (LiveContainer) | Auto-play confirmed with v3.5; **8,192 reached** (2026-11-03), 4,096 several times |
| 2048 version | 4.0.8 only (others untested) |
| Game mode | Regular game (4×4) only |
| Ads and popups | Not detected (turn AUTO off and on again by hand) |
| Host simulation (2 / 4 spawns, up to v3.5) | 8 of 16 runs reached 4,096 (mean best tile 2,976) |
| Host simulation (all spawns are 4, v3.9) | 18 of 24 runs reached 8,192 (mean best tile 7,168) |
| Host simulation (all spawns are 4, v3.9, up to 9,000 moves) | **16,384 on both runs** (318,160 / 323,984) |

v3.5 forces every spawned tile to be a 4, which gains one tier (4,096 in a 2-spawn game is
worth 8,192 in a 4-spawn game). The tiles on screen still read 2: the game's own arithmetic runs on
4s, which is why two "2"s merge into an 8. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

The simulation uses very few runs and says nothing about the success rate on a device.
The deeper endgame search makes each move about 2.5 times slower than in v3.8
(60 to 75 ms per move on the host, longer near the end of a game).
Only one device (the author's) has been tested; reports for other devices and versions are welcome in Issues.

## Download

Get `Auto2048.dylib` from [Releases](../../releases/latest).
The game and its IPA are not included.

## Usage

1. Put `Auto2048.dylib` in the game's tweak folder in LiveContainer and launch. Remove any older copy first.
2. Open the regular game. An `AUTO` button appears at the bottom-right (OFF on launch).

### AUTO button

| Action | Effect |
| --- | --- |
| Tap | ON / OFF |
| Long press | Cycle speed (`x1` → `x2` → `x4` → `MAX`) |

- Only the speed is saved; auto-play always starts OFF.
- `THINK` means searching, `PAUSE` means the game is paused, and `STALE` means the board changed and the
  search result was discarded. All three are normal.
- The 2048 achievement screen shows `PAUSE`. If AUTO remains ON, pressing Continue resumes auto-play.

### RETRY button

| Action | Effect |
| --- | --- |
| Tap | ON / OFF (OFF on launch) |

- While ON, every game over presses "play again" for you, and this repeats until you turn it off.
- Turning it ON also turns AUTO on (a game over can only happen while auto-play is running).
- Each game is written to the game-over log, so a retry session leaves one block per game.

### Game-over log

When the game is over, the final board is appended to `Documents/LCAC-2048_over.log`
inside the app's container. One block per game, with the **dylib version, time, score and board**.

```
2026-11-04 21:15:03 +0900 v3.6 score=146544
  4096   8192   1024    256
    32     64      8      4
   256    512    256     64
     4   1024   8192   4096
```

- Values are the real ones; a tile the screen draws as 2 is recorded as 4 once rewritten.
- If the score cannot be read the line shows `score=-1`; the board is still written.
- The file is appended to, so previous games stay in it.

### When it does not work

A missing button, a stuck `I_CLASS` / `F_EXC`, a halt at an ad, and similar symptoms are covered in
**[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** (Japanese): what each state means and what to do.

## Notes

- Ads and popups are not reliably detected. Turn AUTO OFF before they appear and resume after closing them.
  To remove ads, use something like [LCAB](https://github.com/mar1mo-41414/LCAB).
- Auto-play changes scores and saved data. Back up your save first if needed.
- Challenge and multiplayer modes, non-4×4 boards, automatic restart, and automatic popup handling are not supported.
- The tweak relies on internal game classes and methods, so game or LiveContainer updates may break it.
  Follow your environment's instructions for re-signing when needed.
- The game, its extracted data and saves are not part of this repository.

## Build

Requires [Theos](https://theos.dev) and an iOS SDK.

```bash
make FINALPACKAGE=1
```

The generated `Auto2048.dylib` is usually under `.theos/obj/`. Sign it as required by your environment.

Pushing a `vX.X` tag makes GitHub Actions build the tweak on macOS and attach the dylib to the release.
No binary is kept in the repository; releases are the only place the dylib is distributed.

## Tests

Theos is not needed; a host C compiler is enough.

```bash
make test        # unit tests + a 10,000-board move comparison
make simulate    # quick simulation (3 games × 5,000 moves; takes a few minutes)
```

The same checks run in GitHub Actions (`.github/workflows/tests.yml`).
`Engine.m` / `Controller.m` need the iOS SDK and a device, so CI does not build them.

## Turning a score log block into a board image

`tools/board_image.py` draws one game from `Documents/LCAC-2048_over.log` as an image
that looks like the game itself, score included.

```bash
python3 tools/board_image.py LCAC-2048_over.log --list      # list the recorded games
python3 tools/board_image.py LCAC-2048_over.log             # the last game as PNG
python3 tools/board_image.py LCAC-2048_over.log --block 12  # the 12th game
pbpaste | python3 tools/board_image.py -                    # pass a single block
```

- PNG output needs Pillow (`pip install pillow`); without it the script writes SVG, which
  opens in any browser or Quick Look (`--format svg` forces it).
- Numbers are the log's own values (the game's internal values). Add `--spawn2` to match the
  screen, which renders **only a freshly spawned 4 as "2"** (the forced-4 builds rewrite the cell
  to 4 without redrawing it). Every other tile reads the same on screen and in the log.
- `--scale 2` for a larger image, `--out FILE` to choose the output path.
- Colours are **sampled from real screenshots of the game itself (`com.ketchapp.2048` 4.0.8)**:
  tiles, board frame, empty cells and background. 16,384 and above are not sampled yet
  and are drawn in dark grey.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how it works (game objects, search, threading, states)
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — states and symptom-by-symptom fixes
- [HISTORY.md](HISTORY.md) — development log (analysis, rejected ideas, device results)
- [AGENTS.md](AGENTS.md) — instructions for AI agents working in this repository

The documents under `docs/` are written in Japanese.

## Sister projects

- [LCAC-A](https://github.com/mar1mo-41414/LCAC-A) — an auto-clear tweak for the puzzle game Arrows;
  the UI and IL2CPP handling here follow it.
- [LCAB](https://github.com/mar1mo-41414/LCAB) — an ad-blocking dylib for LiveContainer.

## License

The code in this repository is licensed under the [MIT License](LICENSE).
The game and third-party software remain subject to their own rights and licenses.
