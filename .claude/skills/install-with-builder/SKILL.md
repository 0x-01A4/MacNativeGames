---
name: install-with-builder
description: Set up the Mac and run the MacNativeGames Builder (the window that builds a game app) for a player, from their own game file and prod.keys, for any game the Builder offers (Tears of the Kingdom, Breath of the Wild, Bayonetta 3, Super Mario Odyssey, Metroid Dread, and every games/<name>/game.json with a build script). Use when a player wants to build or install a game with the Builder or a window, asks for "the UI", "the app that builds the games" or `make`, or pastes an error the Builder shows.
---

# Build a game with the Builder

You are helping a player turn **their own** game dump into an app with the Builder: a Mac window that runs the build
(`build_app.py`) and shows its steps. You get the Mac ready and open the Builder with the player's files already in it.
The player makes the choices in the window: where the app goes, and for which device. You explain each page, follow the
build, and fix what stops it. This file works for any assistant. Commands run from the repository folder.

## Rules

- **Only the player's own files.** Never search the internet for, download, or ask anyone for game files, `prod.keys`,
  title keys or firmware. If something is missing, tell the player what to dump from their own Switch and stop.
- **Never print, copy or paste key values.** Find `prod.keys` by its name and pass its path. Never `cat` or open it.
- **Never weaken a check.** Do not edit `expected-*.json`, `game.json`, `build_app.py`, the build scripts or the
  Makefile to get past an error. The error text names the fix.
- **The player chooses.** The Builder fills in nothing by itself. Ask the player where the app should go and for which
  device, and tell them what to pick. Don't choose for them.
- The app contains the game. It is for this player only. Don't upload it or offer to share it.
- Speak the player's language. Find what you can yourself, and ask only for what you can't find.
- Anything that needs `sudo`, a password or a click in a macOS dialog: ask the player to do it. In Claude Code, typing
  `! <command>` runs a command in this session.

## 1. Repository and tools: `make`

```sh
git pull                 # many build errors are already fixed on main; skip if the player has local changes
make                     # checks the tools, builds the Builder if needed, opens it
```

`make` runs `ui/Builder/setup.sh` first. That script checks for Apple silicon, macOS 26 or later, the Xcode command
line tools, Homebrew, and Homebrew's `python@3.14`, `opus` and `libvpx`. It never installs anything without a yes:

| `make` stops with | Do |
|---|---|
| `needs a Mac with Apple silicon` / `needs macOS 26 or later` | Stop: this Mac can't run the games. |
| `The Xcode command line tools are missing` | The player runs `xcode-select --install` and clicks through the dialog, then you run `make` again. |
| `Homebrew isn't installed` | The player installs it from <https://brew.sh> (it asks for their password), then you run `make` again. |
| `Homebrew packages missing: …` and `Install them with: brew install …` | Your shell has no terminal to ask on, so it didn't install. Ask the player whether you may install them. If they agree, run `YES=1 make`. |
| `no macOS 26 SDK that … can use` | The developer tools don't match macOS. Run `softwareupdate --list` and have the player install the command line tools update, or Xcode 26. |

When `make` succeeds, the Builder window is open. It finds this repository by itself.

## 2. The player's files

Ask where they are, or look for names only:

```sh
find ~ /Volumes -maxdepth 5 \( -iname '*.xci' -o -iname '*.nsp' -o -iname '*.nsz' -o -iname 'prod.keys' \) 2>/dev/null
```

The Builder builds every game whose `games/<name>/game.json` names a `build` script. Its `files` say which extensions
it takes, and `"update": []` means the game file already holds its update. The Builder identifies the game and version
from the file's content, so a file name doesn't need to be right. Title IDs and the supported versions of the Zelda
games are in `.claude/skills/install-zelda/SKILL.md` (step 2), and other games' in `games/<name>/README.md`. A
compressed base game (NSZ/XCZ) isn't accepted.

## 3. Open the Builder with the files in it

```sh
make KEYS="<prod.keys>" GAME="<game file>"                         # quote every path
make KEYS="<prod.keys>" GAME="<base game>" UPDATE="<update.nsp>"   # a game with a separate update
```

This works whether or not the Builder is open: the files arrive as if opened in Finder. The Keys page has the keys,
and the Game page has the game file and starts reading it (a few seconds, and it needs the keys).

## 4. Guide the player through the window

Tell the player what each page asks. They click.

1. **Your keys**: filled in. *Remember this location* only makes the file chooser open there next time. **Continue**.
2. **Your game**: it names the game and version it found. Depending on the game, it may also ask for:
   - **an update**: the update NSP/NSZ, when the game needs one and it wasn't given;
   - **system fonts**: a folder of the player's own unpacked firmware (`.nca` files), or a folder of the six `.bfttf`
     files an earlier build extracted. NSP base games need this, and Breath of the Wild always does;
   - **add-on content** and **a mod**: optional, only for the games that take them (`docs/mods.md`).
   Files can also be dropped on this page. **Continue** stays greyed out until the page has what it needs.
3. **What to build**: nothing is chosen here.
   - **Build for**: only shown when the game builds for more than one device (Mac, iPhone / iPad, Vision Pro). The
     player picks one.
   - **Save as**: the player clicks **Change…** and picks the app's final place, for example `/Applications`. Moving a
     Mac app later makes its first start compile the shaders again.
   - The page warns when the drive is short of space, when an app there will be replaced (saves are kept), and when
     the build needs something else on the Mac: the full Xcode for Super Mario Odyssey, or Xcode with the iOS SDK plus
     `brew install xcodegen cmake ninja` for an iPhone/iPad build. Install what it names, then come back.
   - **Build**.
4. **Building**: the steps, with a timer each. A first build takes **20–40 minutes**, mostly waiting, and longer on 8 GB
   Macs. The player can keep using the Mac. Quitting asks first. **Cancel** is safe: the next build reuses the finished
   steps. The work folder (shown on the previous page; `TOTK_build/`, `BotW_build/`, `BY3_build/` or `Dread_build/`
   next to the game file) keeps them. To follow along without the window, read the newest file in `<work folder>/logs/`.
5. **Your app is ready**: **Open** starts it. For a phone or tablet, the page gives the command that installs the IPA
   (run it for the player with the device connected). What the first start looks like: install-zelda step 5 for the
   Zelda games, `games/<name>/README.md` for others.

## 5. When the build stops

The page shows a title, what to do next, and the build script's own message below it. That message names the exact
file, size or tool, so read it first. **Copy Full Log** copies everything. It holds file paths but no key values, so
the player can paste it to you. Fix the cause, then press **Build Again**, or **Change Files** to pick other files.

| Title | Cause and fix |
|---|---|
| Developer tools are missing | Install what the message names (often Xcode, or the iPhone tools above), then Build Again. |
| One of the files can't be used | A file is on the wrong field, or it's compressed. The message says which. |
| The game file could not be read | The keys don't come from the console the game was dumped on, or are too old for its update, or the dump is incomplete. The player dumps `prod.keys` again on current firmware. |
| This isn't a supported game file | Another game, or an update picked as the game. The message lists what this checkout builds. |
| This version isn't supported | `git pull`, then `make` again. If it's still unsupported, the player needs a supported version (README). |
| The game data doesn't match | `git pull` first. Otherwise it's an incomplete dump or another version: the player dumps it again. Never edit the hashes. |
| The system fonts are needed | Give the firmware or fonts folder on the Game page. |
| Not enough free space | Free space on the game file's drive, or move the game file to an APFS drive with room. |
| The mod could not be merged | The mod is for another version: build without it, or see `docs/mods.md`. |
| Not available for this target | Pick the Mac. |
| The build failed, with "This Builder reads event schema …" | The Builder and the repository don't match: run `make` again, which rebuilds it. |
| The build failed | Read the message and the log it names in `<work folder>/logs/`. `git pull` and build again once. If it still fails, help the player file an issue (below). |

Still stuck: help the player open an issue at <https://github.com/ly05010419/MacNativeGames/issues> with their Mac
model, macOS version, `git log -1 --oneline`, the title and message, and the end of the log. Never attach keys, game
files, firmware or the app.

## 6. Later

- After `git pull`, run `make`, open **Library**, and press **Rebuild** on an app marked as built from an older checkout.
  It reuses the same files and the same place.
- **Library** also lists work folders and can move one to the Trash. That frees space but makes the next build start over.
- Without a window: the same build runs in Terminal as `python3.14 build_app.py "<game>" -k "<prod.keys>" [--update …]
  -o "<app>"`. For the Zelda games, follow `.claude/skills/install-zelda/SKILL.md`.
