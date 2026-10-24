# MacNativeGames Builder

A Mac app that runs `build_app.py` for you. You pick your keys, your game file, any update and where the app goes, and the
Builder shows the four build steps while they run. Every step is still done by `build_app.py`: the Builder only collects
its arguments and reads its progress. It never reads your keys or game files itself, downloads nothing, and keeps no
game content.

Status: Phase 3 of `UIPlans/ui-plan.md`. It builds the Mac app for Tears of the Kingdom and Breath of the Wild, the
unsigned iPhone/iPad IPA for Tears of the Kingdom (this needs the full Xcode 26, plus `brew install xcodegen cmake
ninja`), Breath of the Wild 1.9.0 with its add-on content packs, and Tears of the Kingdom with a mod folder
(`docs/mods.md`).

The **Library** (the switch at the top of the window) lists the game apps on this Mac: the ones Spotlight finds by
their bundle identifier and the ones this Builder made. For each it shows what it was built from, and whether
`build_app.py` or the game folders changed in the checkout since. **Rebuild** fills in the Build page with the same files
and output (the keys come from the remembered location, or the Keys page asks). **Move to Trash** keeps saves and
settings. Below the apps, each game's shader list contribution file shows how many rows it holds, with **Send…** (the
GitHub form and the file in Finder) and the game's own reminder switch: the Builder writes the same `.reminded` file the
game's launcher reads, so the two always agree. Nothing is sent unless you send it.

## Build and run

Needs macOS 26 on Apple silicon and the Xcode command line tools (`swiftc`); no Xcode project or SwiftPM.

```sh
ui/Builder/make_app.sh          # -> ui/Builder/build/MacNativeGames Builder.app (ad-hoc signed)
ui/Builder/run_tests.sh         # events, error text, and the runner against a stand-in build (no game files)
open "ui/Builder/build/MacNativeGames Builder.app"
```

The app finds this checkout by walking up from its own location; if it can't, its first page asks for the folder.
The build itself needs what `build_app.py` needs (`brew install opus libvpx python@3.14`); the first page lists what
is missing and the command to install it.

To try the app without game files, point it at the stand-in build (a developer option, off unless set):

```sh
BUILDER_SCRIPT="$PWD/ui/Builder/Tests/Fixtures/fake_build.py" FAKE_BUILD=ok \
  "ui/Builder/build/MacNativeGames Builder.app/Contents/MacOS/MacNativeGamesBuilder"
```

`FAKE_BUILD` is `ok`, `fail` (a hash mismatch in step 2), `slow` (to try Cancel), `noheader` or `schema2` (an
out-of-date script). `FAKE_GAME=botw` makes it a Breath of the Wild file (1.9.0 with an update, so the DLC rows show).
While `BUILDER_SCRIPT` is set, a yellow "Test mode" strip says so and no app is written.

## What the Builder keeps

- In its preferences (`org.macnativegames.builder`): the checkout folder, and the location of `prod.keys` only if you
  turn on "Remember this location". The keys themselves are never copied or read.
- Nothing else. The work folder (`TOTK_build/` or `BotW_build/` next to the game file) is `build_app.py`'s, and it is
  reused by the next build, which is how a cancelled build resumes.
- "Copy Full Log" copies the build's messages, which include the paths of your files but no key material.

## What an app records about its build

Each Mac app `build_app.py` builds carries `Contents/Resources/build-info.json` (sealed with the app; `build_info` in
`build_app.py`, schema 1): `game`, `app_name`, `version`, `display_version`, `platform`, `built` (UTC), the checkout's
`commit` and whether it had local changes (`dirty`; both null outside a git checkout), and `inputs`, the files given to
the build (`game`, `update`, `dlc`, `mod`, `install_mod_romfs`, `firmware`, `shared_fonts`; what was not given is left
out). The keys file is never named in it. An app counts as built from an older checkout when
`git diff <commit> HEAD -- build_app.py games/totk games/botw` is not empty. IPAs carry no record yet.

## The `build_app.py` contract (event schema 1)

With `--json-progress`, `build_app.py` writes one JSON object per line on stdout instead of its text, and its error text
still goes to stderr. Each object has `type` and `time` (Unix seconds):

| type | fields | when |
| --- | --- | --- |
| `hello` | `schema` (1) | first line; the Builder refuses a different schema |
| `progress` | `stage` (`prepare`, `code`, `data`, `update`, `shaders`, `app`), `step` (0–4), `of` (4), `message` | each step message; a message without a `N/4 name:` prefix keeps the stage before it |
| `heartbeat` | as `progress` | "still running" every minute of a long tool |
| `inspect` | `game`, `app_name`, `version`, `display_version`, `kind`, `needs_fonts`, `platforms`, `dlc`, `work`, `default_out` | with `--inspect`: what the game file is; then it stops before the disk checks and the steps |
| `notice` | as `progress`, plus `code` (`npdm_signed`, `npdm_resigned`, `fonts_other_firmware`, `sdk_fallback`) | an input accepted by another rule than the exact reference hash; the Builder lists them when the build ends |
| `done` | `out`, `game`, `version`, `platform` | the app or IPA is ready |
| `error` | `code`, `message`, `log` (the failed tool's log, or null) | exit 1 |
| `cancelled` | | exit 130 (Ctrl-C, or SIGTERM with `--json-progress`) |

Error codes: `toolchain`, `input`, `keys_or_dump`, `wrong_game`, `unsupported_version`, `hash_mismatch`, `fonts`,
`disk_space`, `platform`, `mod`, and `build` for everything else. With `--platform ios`, a missing Xcode (with the iOS
SDK), xcodegen, cmake or ninja is a `toolchain` error before the first step rather than at the last one. The Builder starts `build_app.py` in its own process group
and sends SIGTERM to the group to cancel, so the tools it runs stop too.

Without the new flags, `build_app.py` prints and behaves exactly as before (`tests/test_build_events.py`). A change to
an event's fields that the Builder relies on bumps `EVENT_SCHEMA` in `build_app.py` and `BuildEvent.schema` here.
