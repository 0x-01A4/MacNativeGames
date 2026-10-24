# MacNativeGames Builder

A Mac app that runs `build_app.py` for you. You pick your keys, your game file, any update and where the app goes, and the
Builder shows the four build steps while they run. Every step is still done by `build_app.py`: the Builder only collects
its arguments and reads its progress. It never reads your keys or game files itself, downloads nothing, and keeps no
game content.

Status: Phase 3 of `UIPlans/ui-plan.md`. The Builder knows no game by name: it builds every game whose folder has a
`games/<name>/game.json` (below), and what each one takes (update, fonts, add-on content, a mod, iPhone/iPad) comes from
`--inspect`. Today that is Tears of the Kingdom (Mac app, and the unsigned iPhone/iPad or Vision Pro IPA, which needs the full
Xcode 26 plus `brew install xcodegen cmake ninja` and is installed with `games/totk/ios/tools/install_device.py`; a mod
folder, `docs/mods.md`), Breath of the Wild (Mac or iPhone/iPad; 1.9.0 with its add-on content packs), Bayonetta 3
(Mac; base NSP plus the 1.2.0 update, through `games/by3/build.py`) and Super Mario Odyssey (Mac, needs the full Xcode;
one XCI or NSP holding 1.3.0, through `games/odyssey/build.py`, eight steps).

The **Library** (the switch at the top of the window) lists the game apps on this Mac: the ones Spotlight finds by
their bundle identifier (`bundle_id` in a game.json) and the ones this Builder made. For each it shows what it was built
from, and whether the files its game is built from (`sources`) changed in the checkout since, local changes not committed yet included (an app built with local changes reads "Can't tell"). **Rebuild** fills in the Build page with the same files
and output (the keys come from the remembered location, or the Keys page asks). **Move to Trash** keeps saves and
settings. Below the apps, each game's shader list contribution file shows how many rows it holds, with **Send…** (the
GitHub form and the file in Finder) and the game's own reminder switch: the Builder writes the same `.reminded` file the
game's launcher reads, so the two always agree. Nothing is sent unless you send it.

Under the apps, **Work folders** lists the work folder each build record names, with its size, and moves one to the
Trash. That frees the space and makes the next build of that game start from the beginning. It never removes a folder
the game's app reads from (`work_holds_game_data`) or one that holds an app.

While a build runs, the Mac doesn't idle-sleep, the Dock icon shows the step, and each step shows how long it took.
Quitting asks first and cancels the build. When the build ends with the Builder in the background, a notification
says so. Game files open in the Builder from Finder (Open With, or a drop on its Dock icon) and with File > Open
Game File (⌘O).

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

`FAKE_BUILD` is `ok`, `fail` (a hash mismatch in step 2), `slow` (to try Cancel), `noheader` or `schema1` (an
out-of-date script; `schema1` is one from before this schema). `FAKE_GAME=botw` makes it a Breath of the Wild file
(1.9.0 with an update, so the DLC rows show); `FAKE_GAME=by3` a Bayonetta 3 base NSP, which asks for its update;
`FAKE_GAME=odyssey` a Super Mario Odyssey card image with eight steps.
While `BUILDER_SCRIPT` is set, a yellow "Test mode" strip says so and no app is written.

## What the Builder keeps

- In its preferences (`org.macnativegames.builder`): the checkout folder, and the location of `prod.keys` only if you
  turn on "Remember this location". The keys themselves are never copied or read.
- Nothing else. The work folder (`TOTK_build/`, `BotW_build/` or `BY3_build/` next to the game file;
  `games/odyssey/Odyssey_build/` for Super Mario Odyssey) is the build script's, and it is reused by the next build, which is how a cancelled build resumes.
- "Copy Full Log" copies the build's messages, which include the paths of your files but no key material.

## What an app records about its build

Each Mac app `build_app.py` builds carries `Contents/Resources/build-info.json` (sealed with the app; `build_info` in
`build_app.py`, schema 1): `game`, `app_name`, `version`, `display_version`, `platform`, `built` (UTC), the checkout's
`commit` and whether it had local changes (`dirty`; both null outside a git checkout), the `work` folder (left out by
builds from before it was recorded), and `inputs`, the files given to
the build (`game`, `update`, `dlc`, `mod`, `install_mod_romfs`, `firmware`, `shared_fonts`; what was not given is left
out). The keys file is never named in it. An app counts as built from an older checkout when
`git diff <commit> HEAD -- <its game's sources>` is not empty. IPAs carry no record yet.

## A game's manifest (`games/<name>/game.json`, schema 1)

Every game is a Switch or Switch 2 game built from the player's own dump and `prod.keys`. Each game folder describes
itself; `build_app.py` reads the same files (`GAMES`), and `tests/test_game_manifests.py` checks them against its
tables. A new game is a new folder with a game.json and a build script that speaks the contract below; the Builder needs
no change.

| field | | |
| --- | --- | --- |
| `schema`, `id`, `name` | required | `id` is the game's name in the events and in build-info.json |
| `title_id` | required | the base game's title ID. `build_app.py` hands the game's files to `build`: an NSP at once (read from its tickets, without keys), a card image once `identify_game` has read it with the keys (`hand_over`; the script then writes no second `hello`) |
| `bundle_id`, `data_folder` | | the app's identifier (the Library finds it by this) and its folder in `~/Library/Application Support/MacNativeGames` |
| `data_beside_app` | instead of `data_folder` | the name of the folder next to the app that holds its saves (Super Mario Odyssey: `Odyssey Data`) |
| `build` | | the build script, relative to the checkout (`build_app.py` for the Zelda games). Without one the game isn't offered |
| `sources` | | the paths that go into its app, for "checkout changed" |
| `files` | default: `{"game": ["xci", "nsp"], "update": ["nsp", "nsz"]}` | the file extensions it is built from (`"update": []`: one file holds the update); a file whose extension only one build takes goes to that script directly, others to `build_app.py` |
| `versions` | optional | the versions it builds, when its `assets/expected-*.json` carry no `display_version` |
| `shader_contribution` | optional | `step` and `form` of the game's shared shader list reminder |
| `needs` | optional | what its Mac build needs besides `build_app.py`'s own tools: `xcode` (the full Xcode); the Output page names it and holds the build until it's there |
| `work_holds_game_data` | optional | `true` when its app reads the game data from the work folder (Bayonetta 3), so the Library never deletes that folder |
| `install_tool` | optional | the script that signs and installs its iPhone/iPad or Vision Pro IPA, relative to the checkout; the result page gives the command |

The versions in the error text come from `versions`, or else the `display_version` of `games/<name>/assets/expected-*.json`.

## The `build_app.py` contract (event schema 2)

Every build script (`build_app.py`, `games/by3/build.py`) takes the game file first, then `-k <prod.keys>`, `--update`, `--firmware`/`--shared-fonts`, `-o`, `--platform`, `--inspect` and `--json-progress`, and
refuses an option its game doesn't take with an `input` or `platform` error. With `--json-progress`, `build_app.py` writes one JSON object per line on stdout instead of its text, and its error text
still goes to stderr. Each object has `type` and `time` (Unix seconds):

| type | fields | when |
| --- | --- | --- |
| `hello` | `schema` (2) | first line; the Builder refuses a different schema |
| `progress` | `stage` (`prepare`, `code`, `data`, `update`, `shaders`, `app`, or a game script's own), `step` (0–`of`), `of` (4 for `build_app.py`), `message` | each step message; a message without a `N/M name:` prefix keeps the stage before it. The Builder's step list follows `of` and the stage names |
| `heartbeat` | as `progress` | "still running" every minute of a long tool |
| `inspect` | `game`, `app_name`, `version`, `display_version` (both null until the update is given, when it is needed), `kind`, `needs_fonts`, `needs_update`, `platforms`, `dlc`, `dlc_max` (how many `--dlc` packs; optional, 2 when missing), `mod`, `space_gb` (per platform), `work`, `default_out` | with `--inspect`: what the game file is and what the build takes; then it stops before the disk checks and the steps |
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
