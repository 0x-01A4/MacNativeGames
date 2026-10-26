# Metroid Dread port: work log

A record of how this port is being made, for anyone who continues it or tries the same with another game. Each entry
says what was found, what was done and why, what went wrong on the way, and how it was checked. Newest entries go at
the bottom of [Log](#log); [Status](#status) is kept current. The Bayonetta 3 log (`games/by3/CHANGELOG.md`) is the
method this port follows.

Conventions: dates are absolute; "verified" means a check with a recorded result, never "it looked right"; commits are
named by hash and subject. Game data, keys and saves are never committed (see the Metroid Dread block in `.gitignore`).

## Status

| Stage | Goal | State |
|---|---|---|
| 0 | Feasibility: does the game fit the TotK architecture? | done 2026-10-25 |
| 1 | Code and data out of the dump; code rewritten for Apple silicon | done 2026-10-25 |
| 2 | A runtime target with the other games' parts compiled out, booting to `nnMain` | done 2026-10-25 |
| 3 | Follow every unknown service / command / NVN call until the first `nvnQueuePresentTexture` | in progress: headless boot reaches the VI display service |
| 4 | A picture, audio, input, saves | not started |
| 5 | Performance, shaders, packaging as an app | not started |

## Log

### 2026-10-25: stage 0, feasibility

Input: the base game card image `010093801237C000` v0 (1.0.0, 4.4 GB XCI), `prod.keys` from the same Switch. The card
holds four NCAs (Program, Control, Legal, Meta), all of the base title: no update, no sparse sections.

Findings, each read from the dump:

- **Same module layout as TotK and Bayonetta 3**: `main`, `sdk`, `subsdk0`, `rtld`, `main.npdm`. SDK 11.4.3 (nnSdk, NVN,
  movie, libz, NintendoWare Atk). main build ID `49161D9CCBC15DF944D0B6278A3C446C006B0BE8`.
- **Graphics are NVN.** main loads 524 names; 523 are in the graphics layer's table (the other is
  `nvnBootstrapLoader` itself), 425 have an implementation in one of the three forks. 46 of the missing ones are not
  getters (transform feedback, downsample, `ReportValue`, integer clears, tessellation levels, ...): a call aborts
  with its name, so stage 3 lists the ones the game uses.
- **Audio** is NintendoWare Atk through `nn::audio` (149 imports), not Wwise. **Movies** use Nintendo's movie library
  (subsdk0 carries the WebM parser); the title screen, the prologue and the loading trains are `.webm`.
- **Data**: Lua 5.1 scripts and `packs/*.pkg` archives.
- **The npdm allows 47 services**, a set close to Bayonetta 3's (`nifm`, `bsd`, `ssl`, `friend`, `bcat`, `prepo`, ...).
- **The rewriter fails on main.** sdk and subsdk0 rewrite with the generic scan; main stops with an out-of-range branch
  (`AssertionError` in `B()`). main's `.bss` is `0x70ccf788` bytes (1.8 GiB). The patch area goes after the image
  (`PATCH_OFF = page_up(text + rodata + data + bss + key page)`), about 1.93 GB from the text, and a site's `B` reaches
  ±128 MiB.

### 2026-10-25: the fork, stage 1

**Layout.** `games/dread` is a copy of `games/by3` (commit `6142be3` is the unchanged copy, so the following commits'
diff is the whole fork). Bayonetta 3 is the newest fork (`site_spset`, CMIF domains, `audout:u`, `set`, offline
network services, RomFS listing). The work folder is `games/Dread_build`, next to the card image.

**Code and data.** The fork's `extract_exefs.py` / `extract_romfs.py` (TotK's, as Bayonetta's copies) select the base
Program NCA of `010093801237C000` without BKTR and refuse anything else. Bayonetta's sparse-RomFS merge, update-code
extractor and 1.2.0 patch scripts are removed.

Verified: ExeFS FS header, hash table and every block; RomFS all six IVFC levels (268,575 data blocks; 9,654 files,
4,400,319,820 bytes, SHA-256 `d3c6c310…`, matching an independent `shasum`); one byte flipped in a level-5 read fails
block 17,408. `assets/expected-v1.0.0.json` pins all of it.

Commit: `5079033` feat(dread): extract and verify the code and RomFS of Metroid Dread 1.0.0.

### 2026-10-25: the leading patch area

**Rewriter.** When the patch area after the image would be out of branch reach (`PATCH_OFF >= 2^27 - 1 MiB`),
`patch_nso.py` places it `PATCH_LEAD` (4 MiB) before the module, growing towards offset 0. The key page stays after
`.bss`: ADRP reaches ±4 GiB. The file holds the patch area, padding to `PATCH_LEAD`, and the image up to the end of
data; `.bss` and the key page are zero-filled by the loader (otherwise the file would be 1.9 GB and wholly read on
every start). `fixups.tsv` gains `PATCH_LEAD`, `PATCH_SIZE` and `IMAGE_SIZE`. The encoders already did signed
arithmetic. A first lead of 32 MiB was cut to 4 MiB once main's patch area turned out to be 43 KB (1,085 sites: main's
code rarely uses x18); an assert stops a module whose patch area does not fit.

**Checkers.** `nsoimg.Patched` reads a rewrite by module offset in either layout (zeros past the stored bytes).
`structck.py` and `equiv.py` use it. equiv maps the same range in both emulators and keeps `.bss` out of Python memory.
capstone reports a negative address as unsigned; equiv's `plain_block` and structck's `keyseq` / `paramseq` convert it
back (main has no gates or parameter windows, so structck passed before that fix too).

Verified:

- sdk and subsdk0 rewritten by this fork are byte-identical to the `games/by3` rewriter's output (patched image, gates,
  sites, cuts); `fixups.tsv` differs only by the three new header lines. Two rewrites give identical bytes.
- `structck.py`: OK on all three (main 1,085 sites, sdk 12,085, subsdk0 10,486), the same counts as the unmodified
  checker on sdk / subsdk0. A main copy with one flipped patch word fails (key-slot sequence and slot count), one with a
  non-zero pad byte fails (pad check).
- `equiv.py`: 0 divergent sites on all three; sdk and subsdk0 results identical to `games/by3`'s equiv. Mutation
  control: sdk and subsdk0 300/300. main with seed 1 caught 299/300: the miss is a nop in place of
  `csel x18, x12, x18, eq` at `0x17b008`, which only shows when `eq` holds, and its 3 trials had Z clear. Seeds 2, 3
  and 4 catch 300/300. Recorded as a limit of the mutation control, not changed.

Commit: `8873af7` feat(dread): the rewriter places the patch area before a module whose image is out of branch reach.

### 2026-10-25: the loader, and `nnMain`

**Loader.** `Module` gains `patch_lead`, `patch_size`, `image_size`; `patch_off` is signed. The Mac `map_module`
reserves `patch_lead + image`, reads the file from the reservation's start (the module base is `patch_lead` in) and
checks the file's SHA-256 as before. `seal` makes the lead range RX; `check_permissions` and the page classifier know
it. Crash lines, caller traces and `runtime_module_offset` name a lead address `<module>.patch+offset`. The iOS loader
refuses the layout.

**Fork identity.** Title `010093801237C000`, version 1.0.0 / `v100`, `dread-native`, `org.macnativegames.dread`,
`DREAD_*` environment names, window and menu titles. BY3's 1.2.0 patches, `build.py` and `game.json` are removed
(`build_app.py` reads every `games/*/game.json`; the copied one named Bayonetta 3 again). The defaults
`system_services.c` sets for the graphics layer (pool size, invariance, GPU code versions, 60 Hz pacing) are Bayonetta
3's and are kept until Dread's own are measured. Comments that say which game needed a graphics-layer feature keep
naming Bayonetta 3.

Verified:

- `make prepare`: 198,378 relocations; constructor-state word found the same way in all three modules (adrp x20 at
  +0x10, ldr at +0x18); main's is in `.bss` (`0x1cee0d0`). `make runtime` builds with `-Werror`.
- `make probe`: three modules mapped (main 1,922,859,008 bytes with `.bss`), sealed and permission-checked;
  4,000 main PLT → sdk → host-timer calls on 4 threads. A main image with one flipped patch byte is refused
  ("image SHA256 differs from verified rewrite").
- Headless boot (`TOTK_HEADLESS=1 TOTK_VERIFY_STARTUP=1`): `nn::init::Start` ran the SDK startup on the verified RomFS;
  every constructor finished with state 2 (main 2,751, subsdk0 44, sdk 115 `init_array` entries); the game's `nnMain`
  ran and brought up the Metal device, then stopped at `sm: service "fsp-srv" not implemented` (caller
  `main+0x1910` → `main+0x132b28` → `main+0x13241c` → sdk). Whether one of main's rewrite sites ran on the way was not
  measured.

Not built or run: iOS, the launcher and `make app`, any picture.

Open questions carried forward: why this SDK opens `fsp-srv` over IPC where TotK's and Bayonetta's are answered by
function name; which of Bayonetta's offline services and graphics defaults Dread needs; whether the Atk audio path
matches TotK's audio renderer; the system fonts (the card carries none).

### 2026-10-25: stage 3 (in progress), from `nnMain` to the display

Method as for Bayonetta 3: boot headless, read where the host stops, name the SDK frames (`scripts/symbolize.py`),
fix the platform layer, repeat.

- **`fsp-srv`** was not a missing service: main's first call is `nn::fs::SetAllocator`, which no other port's main
  makes. The SDK's own fs library then checks its access log and opens `fsp-srv` over IPC. The host answers fs by
  name and never allocates guest memory for it, so `SetAllocator` keeps nothing. `DeleteDirectory`, also imported, was
  added (an empty save folder).
- **`nn::oe::EnterExitRequestHandlingSection`** (a null applet object in the SDK's own version): the host never sends
  an exit request, so entering or leaving the section is a no-op.
- **An audit instead of one crash per boot**: main imports 261 SDK functions that no host override answers. Almost
  all are library code on the SDK's own system calls (`nn::os` 53, `nn::util`, `nn::mem`, the `nn::audio` client
  whose service `audren:u` the host answers over IPC, vibration players, play-report builders). Those that would reach
  an unanswered service: the two `oe` sections above and 12 `nfp` calls, now "no device" like the existing ones (they
  need a device handle the host never hands out). `hid::InitializeVibrationDevice` / `GetVibrationDeviceInfo` ran
  without a stop (`[hid] the game initialized its vibration devices`).
- **`nn::os::CreateThread` broke in the SDK** (`ThreadManager::CreateAliasStackUnsafe` failed 64 tries). With
  `TOTK_MEM_LOG` (it now also logs `svcMapMemory`): the stack source was `main+0x1da7000`, in main's `.bss`; the host
  accepted only heap and alias memory. On the console module data (CodeData) is a valid source. The host now accepts
  a range inside one module's data or `.bss` whose pages are all read-write and unlocked
  (`runtime_module_data_rw` in the loader); QueryMemory reports such a source as CodeData.

Verified: the headless boot now runs past account, performance mode, keyboard, vibration devices, AudioOut, four audio
renderers (REV8 update) and three thread creations with stacks from main's `.bss`, then stops at the VI display
service, which needs the native window (`VI requires native macOS window`).

A run with a window could not continue on 2026-10-25: the Mac's screen was locked and the display asleep
(`CGSSessionScreenIsLocked = 1`, no active display), so `CVDisplayLinkCreateWithActiveCGDisplays` returned -6661 and
the runtime stopped at `native display link initialization`. Not a defect of the port; the next run needs an unlocked,
awake display.

Commit: `7a8a428` feat(dread): answer the fs allocator, exit-request sections and nfp calls, and accept thread stacks
in module data.
