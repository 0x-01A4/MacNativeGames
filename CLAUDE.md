# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MacNativeGames runs Nintendo Switch games (Tears of the Kingdom, Breath of the Wild, and a work-in-progress Bayonetta 3) **natively** on Apple silicon (macOS 26+, Metal 4) and iOS/iPadOS 26. The game's own ARM64 code is rewritten ahead of time and executed directly; the project supplies a loader, a Horizon OS service host (HLE) and an NVN-on-Metal graphics driver. Read `docs/how-it-works.md` before touching the loader, runtime or graphics layer, and `CONTRIBUTING.md` for the project's rules (summarised below).

## Commands

Python is 3.14 (the build reads zstd from the standard library). Build-tool test deps: `python3.14 -m pip install -r games/totk/requirements.txt` (`requirements-dev.txt` adds unicorn/Pillow/brotli, only for `make probe-*` diagnostics).

```sh
# All source tests (what CI runs; no game data or keys needed)
python3.14 -m unittest discover -s tests -v

# One test file / one test
python3.14 -m unittest discover -s tests -p test_mouse.py -v
python3.14 tests/test_mouse.py MouseTests.test_look   # each file ends in unittest.main()

# Native C parsers under UBSan, as CI does (ASan hangs in dyld on macOS 26 — don't use it)
cc -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all tests/test_romfs_paths.c -o /tmp/t && /tmp/t
cc -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all tests/test_controller_map.c -o /tmp/t && /tmp/t

# Build the app (needs the user's own game file + prod.keys; work folder TOTK_build/ or BotW_build/ next to the game file is reused across runs)
python3.14 build_app.py <game.xci|nsp> -k <prod.keys> [--update <x.nsp|nsz>] [--firmware DIR | --shared-fonts DIR] [-o OUT]
python3.14 build_app.py ... --platform ios -o TOTK.ipa   # shared runtime / d2r_gfx changes must still build for iOS
```

Developer probes and verification targets live in `games/totk/Makefile` (`probe-*`, `verify*`, `test-*`; `make help`). Native unit tests for graphics/audio/input pieces are under `games/totk/tests/<name>/` and are driven from that Makefile. Bayonetta 3 has its own `games/by3/Makefile` and step-by-step build in `games/by3/README.md`.

Commit messages: `<type>: <description>`, type ∈ feat, fix, refactor, docs, test, chore, perf, ci.

## Architecture

**`build_app.py`** (repo root, single large script) is the whole pipeline: detect XCI/NSP by header → decrypt NCAs with the user's keys (common tickets, NSZ decompression, cumulative-update merge via a pinned hactool built locally) → extract ExeFS and verify RomFS through all IVFC levels → optionally merge mod ExeFS patches into the retail `main` (`games/totk/scripts/mod_exefs.py`) → rewrite the three modules (main, sdk, subsdk0) → generate RomFS overlays and the first-launch shader seed (`prepare_shader_seed.py`) → compile the runtime and package/sign a `.app` or unsigned `.ipa`. Every stage is checked against `games/<game>/assets/expected-v*.json`; a different genuine dump is accepted only via the NPDM ACID signature path.

**Code rewriting** — `games/totk/third_party/d2r/patch_nso.py`: replaces what macOS forbids (x18 platform register, TLS register, `svc`, counter registers) with branches into host stubs. Output is bound by SHA-256; never patch an already rewritten binary.

**Runtime / HLE** — `games/totk/runtime/`: `loader.c` maps and links the modules and calls `nn::init::Start`; `gate.S`/`hle_stack.*`/`thread_enter.S` are the guest↔host transitions; `ipc.c`/`services.c` answer Horizon IPC; `fs_host.c`/`romfs.c` serve RomFS and saves; audio (`audio_*`, Core Audio), input (`input.c`, `gamepad.m`, `mouse_look.h`), movies (libvpx), `frontend.m` (AppKit) / `frontend_ios.m`. Game-code patches are in `game_patches*.c`, each verifying the original instruction before writing. Guest memory must stay below 2^39; the host's memory layout differs between macOS 26, macOS 27 and iOS (see how-it-works).

**Version/game switches** — `runtime/game_version.h` selects game and version by compile-time defines (`GAME_BOTW160`, `GAME_BOTW190`, `TOTK_GAME_V143`, …). TOTK and BotW share `games/totk` with these switches; BotW-only files are excluded from the iOS project in `games/totk/ios/project.yml`.

**Graphics** — `games/totk/third_party/d2r_gfx/gfx/nvn`: implements NVN and replays command buffers on Metal 4 (memory pools → Metal resources with dirty-page tracking). Maxwell shaders are translated by `totk_xlate --service` (Ryujinx translator from `vendor/ryujinx` + patches in `games/totk/tools/totk_xlate`, NativeAOT) → SPIR-V → SPIRV-Cross → MSL. The translator ships prebuilt in `games/totk/prebuilt/macos-arm64` with a SHA-256 check, so neither building nor playing needs .NET. iOS cannot translate at runtime: missing variants are skipped and logged to `shader-list-contribution.txt`.

**Shared shader list** — `games/<game>/assets/shader_list.tsv` holds shader keys and bind states only (never compiled shaders); builds turn it into a seed from the player's own game files. See `docs/shader-list.md`.

**Other games** — each non-Zelda game in `games/<name>/` carries its own full copy of runtime, d2r, d2r_gfx, prebuilt and scripts. A change for one game never edits another game's files.

## Rules that constrain changes

- **Never commit game content**: no code, RomFS files, translated shaders, keys, saves, fonts (see `.gitignore`). Don't copy GPL code or code from other mods; third-party code goes in `THIRD_PARTY_NOTICES.md`.
- **No CPU emulation** in the port (no interpreter/JIT/DBT/Unicorn/QEMU/emulator CPU backends), and don't copy Horizon services/IPC/schedulers from emulators. Emulators are allowed only as an external reference (e.g. verification scripts).
- **Fix the platform layer, not the symptom** in game code. Feature patches (FPS, aspect, resolution) must check original bytes and fail on mismatch.
- The NVN layer maps NVN semantics only — no camera/scene/gameplay logic; game-specific hacks sit apart, are justified, switchable, and never required to run.
- Don't change `expected-*.json`, `game_version.h` version tables, keys or defaults unless that's the point of the change. New build steps record their inputs/outputs in the existing checks.
- Picture correctness before speed. Mac: no visual loss for performance. iOS: slight loss allowed (never lower resolution), behind an iOS condition so the Mac picture is unchanged.
- Diagnostics and unfinished experiments are off by default (env var or input-file command).
- Changes need to build for every affected game version and for iOS when shared code is touched; say what was and wasn't built/played.
