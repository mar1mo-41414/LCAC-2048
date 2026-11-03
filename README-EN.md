# Auto2048 — an auto-play tweak for 2048 on LiveContainer

[日本語 README →](README.md)

A tweak (dylib) that plays the regular mode of **2048** (`com.ketchapp.2048`) on
[LiveContainer](https://github.com/LiveContainer/LiveContainer).
It searches up to four moves ahead and picks the next swipe. **Reaching 2048 is not guaranteed.**

- **Automatic moves** — scores legal moves using empty cells, monotonicity, a snake pattern and more.
  Empty cells are scored by count and by whether they are connected to other free space.
  When the two highest tiles can be joined, it always takes that move.
- **Adjustable speed** — long-press the button to cycle through `x1` / `x2` / `x4` / `MAX`.
- **Deeper search** — a per-move node budget, so the search reads 4 to 6 moves ahead.
- **Spawn value forced to 4 (experimental)** — it looks for the game's "chance of a 4" and
  raises it to 1.0. When that does not work it falls back to 2 / 4 on its own
  (see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)).
- **Visible state** — the button shows `THINK` / `STALE` / `PAUSE` and so on.
  What each one means: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) (Japanese).
- Targets the regular 4×4 game in 2048 **4.0.8** only. Challenge and multiplayer modes are not supported.

## Status

| Item | State |
| --- | --- |
| Real device (LiveContainer) | Auto-play confirmed with v3; one 2048 achievement observed |
| 2048 version | 4.0.8 only (others untested) |
| Game mode | Regular game (4×4) only |
| Ads and popups | Not detected (turn AUTO off and on again by hand) |
| Host simulation (2 / 4 spawns) | 8 of 16 runs reached 4096 (mean best tile 2,976) |
| Host simulation (all spawns are 4) | 3 of 8 runs reached 16,384, four reached 8,192, one 4,096 |

The simulation uses very few runs and says nothing about the success rate on a device.
The deeper search makes each move slower than in v3.3, especially near the end of a game.
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
