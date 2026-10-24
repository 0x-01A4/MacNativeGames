# UI Plan

A graphical front end for MacNativeGames. The review in `PlanNotes.md` turned the first draft's questions into
decisions; what is still open is listed at the end. How to build and run the Builder, and the event contract: `ui/README.md`.

## 1. Decided

| Question | Decision |
| --- | --- |
| Builder or Launcher first | Builder first (Phases 1–2), Launcher in Phase 3 |
| In-game overlay | Not in scope (non-goal) |
| Platforms | The Builder runs on the Mac and also builds the iPhone/iPad IPA (Phase 2). There is no UI on iOS |
| Where it lives | In this repository, `ui/`. One Builder serves every game, and the game folders stay separate |
| Game agnostic | The Builder names no game. Every game is a Switch or Switch 2 game the player owns, built from their dump and `prod.keys`. Each game folder has a `games/<name>/game.json`; what a game takes comes from `--inspect` (schema 2), and the step list from its progress events. `build_app.py` stays the entry point and hands a game with its own build script over to it (an NSP by its tickets, a card image after identification) |
| Technology | Native SwiftUI, **not sandboxed**: the build starts cc, clang, codesign, git and hactool, which a sandboxed app can't |
| How it's built | `ui/Builder/make_app.sh` with `swiftc` only (no Xcode project or SwiftPM), ad-hoc signed. Distribution is "build from source" until Phase 5 |
| Python 3.14 | Detected in the same places as `build_app.py` (`/opt/homebrew/bin`, `/usr/local/bin`). If it's missing, the first page shows the `brew install` command. It's not bundled, because the build needs Homebrew's opus/libvpx and the Xcode tools anyway |
| UI ↔ script contract | `build_app.py --json-progress` (JSON lines, schema 1) and `--inspect`. Text output without the flags is unchanged |
| Stage names | `build_app.py`'s four steps are authoritative: code, data (or update), shaders, app, plus a prepare step 0 |
| Flow | A wizard: Keys → Game (identified by `--inspect`, because identifying needs the keys) → Output → Build → Done |
| Remembering paths | The checkout folder is always remembered. The `prod.keys` location is remembered only when the player opts in, and only the path, in the app's preferences |
| Work folder | Always reused (`build_app.py`'s default next to the game file). That's also how a cancelled build resumes. A "clean rebuild" button is open (§6) |
| Cancel | SIGTERM to the build's process group. `build_app.py` exits 130, and the next build reuses the finished steps |
| Errors | `BuildError` carries a code. The Builder shows a plain-language title, the next step, and the script's own message underneath. "Copy Full Log" holds paths but never key material |
| Verification detail | Pass/fail per step by default. Hashes and stage text are in the expandable log |
| Look | Stock macOS: a step list, grouped forms, system colors, dark/light mode |
| Cover art | None. It would be game content |
| Localization and accessibility | `String(localized:)` and accessibility labels from Phase 1. Chinese follows in Phase 5 without a retrofit |
| Bayonetta 3 | Built by the Builder through `games/by3/build.py`, the README's steps behind the same event contract (Mac only, base NSP plus the 1.2.0 update) |
| Clean rebuild | The Library lists the work folders with their size and moves one to the Trash, unless the game's app reads from it (game.json `work_holds_game_data`) or an app sits inside it |
| Disk space | The Output page compares the work folder's drive with the inspect event's `space_gb` and warns; `build_app.py` stays the check that stops a build |
| Super Mario Odyssey | Built by the Builder through `games/odyssey/build.py`, which runs `scripts/build_odyssey.py`'s eight steps (its own command line unchanged) behind the same event contract (Mac only, needs Xcode) |

## 2. Non-goals

- No in-game overlay or menu, and no change to the game's own hotkeys.
- No game content: no cover art, no bundled keys, firmware, fonts or shaders, and no downloads of them.
- No reimplementation of anything `build_app.py` does. The Builder never opens keys or game files itself.
- No emulator-style features (save states, cheats, CPU options).

## 3. Architecture

- **Builder app** (`ui/Builder/Sources`): `Core/` holds the event parser, the process runner, preflight and error text, and it's tested without UI. `App/` holds the wizard model and SwiftUI views.
- **Privileges**: the app runs as the user and is unsandboxed. It runs Python 3.14 with `build_app.py` from the checkout it was built in, or from the folder the user picked.
- **Data**: the app's preferences hold the checkout path and, if opted in, the keys path. Everything else belongs to `build_app.py`: the work folder, logs in `<work>/logs`, and the output app.
- **Version pairing**: the `hello` event's schema has to match the Builder's, or the Builder stops the script and says it needs rebuilding from the same checkout.

## 4. Builder flow

1. **Keys**: shows what's missing on the Mac (Xcode CLT, Homebrew packages, the checkout) with copyable commands. Then pick `prod.keys`.
2. **Game**: pick or drop the XCI/NSP. `--inspect` names the game and version from its data. An optional update (NSP/NSZ) re-inspects. If the file needs system fonts, it asks for a firmware or shared-fonts folder.
3. **Output**: the Mac app, defaulting to `build_app.py`'s location. It warns that moving the app later recompiles the startup shaders.
4. **Build**: the four steps with the current message, an expandable log, and Cancel.
5. **Done**: Open, Show in Finder and Build Another; a notification and the Dock badge when the Builder is in the background. On a failure: what went wrong, the next step, Copy Full Log, Build Again, and Change Files.

## 5. Delivery phases and definition of done

Each phase is done when its tests pass and the change notes say what was built and played, as the project rules require.

- **Phase 0 (done)**:
  - Built: `--json-progress`, `--inspect`, error codes, cancel on SIGTERM.
  - Tests: `tests/test_build_events.py`.
  - Done means: the text output stays unchanged, and the unit tests pass with no game data.
- **Phase 1 (done, awaiting a real-dump check)**:
  - Built: the minimal Mac Builder for TOTK and BotW, and `ui/Builder/run_tests.sh` against a stand-in build.
  - Done means: a full TOTK build from the Builder with a real dump; the app starts and plays.
- **Phase 2 (done, awaiting real-dump checks)**:
  - Built:
    - the iPhone/iPad target, with an early check in `build_app.py` that Xcode with the iOS SDK, xcodegen, cmake and ninja are installed, and sideloading steps on the result page;
    - BotW 1.9.0 add-on content packs;
    - a TOTK mod folder, with an opt-in to install its RomFS files (the warning says the mod folder is replaced and the old one kept as a backup);
    - the shader reminder toggle for iOS;
    - `notice` events: a dump accepted through Nintendo's ACID signature or a re-signed npdm, and fonts from another firmware version.
  - The ACID notice is a build event rather than an `inspect` field: the base game's main.npdm is only extracted during step 1.
  - The sideload explanation stays generic: no tool is recommended. That needs an owner if a specific one is to be documented.
  - Done means: an IPA, a BotW 1.9.0 build with DLC, and a TOTK build with a mod, each made from the Builder.
- **Phase 3 (done, awaiting a real build)**:
  - Built:
    - every Mac app records what it was built from, in `build-info.json`;
    - the Builder's Library lists apps found by Spotlight and the ones it built itself, marks an app as "checkout changed" when `build_app.py` or `games/totk` / `games/botw` changed since its commit, and rebuilds an app with the same inputs over the same app, or moves it to the Trash;
    - the shader contribution files with Send and the reminder switch.
  - The contribution state stays in the game's own `.reminded` file, so the in-game launcher and the Builder never disagree. Its "Submit automatically" (with gh) stays only in the game.
  - IPAs carry no record yet, so they're not listed.
  - Apps built before this change are listed with "no build record": rebuilding once from the Build page gives them one.
  - Done means: a Mac app built from the Builder appears in the Library, and after a commit to `games/totk` it shows "checkout changed" and rebuilds.
- **Phase 4**:
  - Scope: game settings as launch options. Only the options each game and version supports, read from a manifest rather than hardcoded.
  - Done means: settings take effect when the app is started from Finder, not only from the Launcher.
- **Phase 5**:
  - Scope: Chinese localization, an accessibility audit, and distribution (signed/notarized, or Homebrew).

## 6. Open

- **Work folder on a read-only or external drive**: let the player pick `--work` in the Output step?
- **How settings reach the game** (Phase 4): environment variables only work when the Launcher starts the game. The other route is a per-app settings file that the runtime reads, which also works from Finder.
- **A CI job for the Builder**: `run_tests.sh` needs a Swift toolchain on the runner. The Python half is already in CI through `tests/`.
- **Distribution** (Phase 5): a notarized DMG or Homebrew cask, and how the Builder learns that the checkout has a newer revision.
