# Auto2048 — an auto-play tweak for 2048 on LiveContainer

[日本語 README →](README.md)

A tweak (dylib) that plays the regular mode of **2048** (`com.ketchapp.2048`) on [LiveContainer](https://github.com/LiveContainer/LiveContainer).

- **Automatic moves** — searches up to four moves ahead. Reaching 2048 is not guaranteed.
- **Adjustable speed** — long-press the button to cycle through `x1` / `x2` / `x4` / `MAX`.
- Targets the regular 4×4 game in 2048 **4.0.8**. Auto-play and one 2048 achievement have been observed on a physical device with v3.

## Download

Get [`Auto2048.dylib`](Auto2048.dylib) from this repository. The game and its IPA are not included.

## Usage

1. Put `Auto2048.dylib` in the game's tweak folder in LiveContainer and launch. Remove any older copy first.
2. Open the regular game. An `AUTO` button appears at the bottom-right (OFF on launch).

### AUTO button

| Action | Effect |
| --- | --- |
| Tap | ON / OFF |
| Long press | Cycle speed (`x1` → `x2` → `x4` → `MAX`) |

- Only the speed is saved; auto-play always starts OFF.
- `THINK` means searching, `PAUSE` means the game is paused, and `STALE` means the board changed and the search result was discarded.
- The 2048 achievement screen shows `PAUSE`. If AUTO remains ON, pressing Continue resumes auto-play.

## Notes

- Ads and popups are not reliably detected. Turn AUTO OFF before they appear and resume after closing them.
- Auto-play changes scores and saved data. Back up your save first if needed.
- Challenge and multiplayer modes, non-4×4 boards, automatic restart, and automatic popup handling are not supported.
- The tweak relies on internal game classes and methods, so game or LiveContainer updates may break it. Follow your environment's instructions for re-signing when needed.

## Build

Requires [Theos](https://theos.dev) and an iOS SDK.

```bash
make FINALPACKAGE=1
```

The generated `Auto2048.dylib` is usually under `.theos/obj/`. Sign it as required by your environment.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for technical details and [HISTORY.md](HISTORY.md) for the development log (both in Japanese).

## License

The code in this repository is licensed under the [MIT License](LICENSE). The game and third-party software remain subject to their own rights and licenses.
