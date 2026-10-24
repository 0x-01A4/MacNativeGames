# Super Mario Odyssey: changelog

## Status

Stage 4 reached: from the new-game menu through the opening scene on Bowser's airship (with music) into Cap Kingdom,
where Mario walks under keyboard control and the play guide movies (H.264) play. Not played further than the first
minutes; the first trip through each scene stutters while its shaders are translated (no shared shader list yet).

## Log

### 2026-10-21: stage 0, feasibility

Inputs: base `0100000000010000` v0 (5.6 GB NSP), update 1.4.1 `0100000000010800` v393216 (0.4 GB NSP), `prod.keys`
from the same Switch. The display version 1.4.1 is read from the update's control data (`control.nacp`; the same
read gives 1.4.3 for the Tears of the Kingdom update).

Findings, each from the port probe (`tools/port_probe.py`, a separate change) with Tears of the Kingdom 1.4.3 as the
reference:

- **The update moves the game to SDK 7.3.2** (the base 1.0.0 is SDK 3.5.1). Breath of the Wild 1.6.0, which the TotK
  host runs with its `GAME_BOTW` switches, is an SDK 7 game too.
- **The base code does not rewrite; the update code does.** On 1.0.0 `patch_nso.py` stops in subsdk0
  (`AssertionError: jump table 1a8884`); on 1.4.1 all three modules finish.
- **Graphics are NVN.** Of the 465 names the game carries, 383 are implemented, 4 are deliberate no-ops, 75 are in
  `names.txt` without an implementation and 3 are NVX extensions not in the table. Tears of the Kingdom carries 77 of
  these 78 missing names too, and runs.
- **The npdm allows 44 services**, all listed by Tears of the Kingdom too.
- **279 SDK imports are unproven**: no running game makes them natively yet. The largest groups are audio (27), sockets
  (46) and SSL (17), BCAT (18), hid vibration (15), the nnos C API (19) and 11 NVIDIA driver functions the game
  imports directly (`NvRmChannelDup` and others). The last group is the riskiest: the host replaces the NVN driver as a
  whole, so a direct call goes around it.
- Calibration: Tears of the Kingdom 1.0.0 against 1.4.3 shows 17 unproven imports and 2 unhandled SVCs, and it runs.
  The numbers are upper bounds.

### 2026-10-21: stage 1, code and data

**Code.** `scripts/extract_code.py` takes the ExeFS from the update with every block verified; the result matches the
probe's independent extraction byte for byte. `patch_nso.py` (a copy of `games/totk/third_party/d2r`, unchanged)
rewrites sdk (11,449 sites, among them 11,297 x18, 60 svc and 32 cntpct), subsdk0 (11,093 x18 sites and one jump
table) and main (1,893 x18 sites) with the build's variables. No new block kind was needed.

Verified: `structck.py` OK for all three modules (0 violations); `equiv.py` 0 divergent sites in main (1,893), subsdk0
(11,093) and sdk (11,357 checked; the 92 gate sites are checked by structck). Mutation controls: 300 of 300 caught in
main and subsdk0. In sdk, seed 1 caught 299 of 300: the missed control replaced `bfi x18, x0, #1, #1` with a nop, and in
its 3 random trials bit 0 of x0 equalled bit 1 of x18, so the nop wrote the same value (a 1-in-8 chance per run).
Seeds 2, 3 and 4 caught 300 of 300 each. Two rewrites give identical bytes.

**Data.** `scripts/merge_romfs.py` rebuilds the RomFS from the base and the update without hactool. Two changes to the
Bayonetta 3 copy:

1. The base Program NCA is complete, not sparse: `PlainBase` reads it as plain AES-CTR with the section's own upper
   IV; the sparse reader stays for a sparse base (chosen by the generation field at 0x170).
2. The update's AES-CTR-Ex table covers only the data before the indirect table (its entries end at 0x15E86C00, the
   indirect table's offset), not everything up to itself as in Bayonetta 3. The indirect table is then plain AES-CTR
   with the header's generation. The script reads the table's extent and accepts exactly these two layouts.

Verified: all six IVFC levels, 346,568 of 346,568 data blocks; 4,972 files, 5.68 GB, SHA-256 `6bb432a4…`;
5.32 GB come from the base, 0.37 GB from the update; flipping one byte of base data fails its block (level 5 block
189,259). `scripts/check_expected.py` checks a work folder against `assets/expected-v1.4.1.json` and fails on one
changed byte.

### 2026-10-21: stage 2, the host, and the game reaches `nnMain`

**Layout.** `games/smo/runtime`, `third_party/d2r_gfx` and `prebuilt/` are copies of `games/totk` (commit `6f41a73` is
the unchanged copy, so the next commit's diff is the whole fork); the Makefile and `scripts/prepare_runtime.py` come from
`games/by3`. Super Mario Odyssey 1.4.1 is SDK 7.3.2, the SDK of Breath of the Wild 1.6.0, so the shared code's
`GAME_BOTW` branches were resolved with `unifdef` per file: kept where they answer the SDK (init order, hid seven-axis
sensor, steady-clock time points, pl fonts and VR mode, CommitSaveData, vi scaling, oe exit sections, account
preselection, the NVN layer), dropped where they are Breath of the Wild itself (DLC volumes, save slots, survey chains,
patches). `threads.c`, `services.c`'s SVC path, `fs_host.h`, `movie_host.c` and `autoload.c` keep the TotK branch.
`game_version.h` defines no game address, as in `games/by3`.

Verified: `make prepare` (3 modules, 226,799 relocations, DT_INIT constructor flags found by decoding); `make runtime`
builds without a warning; `smo-native rewritten/v141 probe` passes (4,000 calls main PLT -> sdk -> host timer on 4
threads); `TOTK_HEADLESS=1 TOTK_VERIFY_STARTUP=1 ... boot` reaches `ENTER nnMain` with every constructor at state 2
(main 191, subsdk0 44, sdk 106 init_array entries) and stops only because the game asks for a window.

### 2026-10-21: stage 3, from `nnMain` to the first screen

Method as in `games/by3`: boot with a window, read where the host stops, answer that, repeat; `scripts/symbolize.py`
names the sdk frames. Answered, in the order the game met them:

- `nn::account::GetLastOpenedUser` (account.c): the SDK's own version read an account service object the host never
  creates (a null read in sdk); the one local user is always the last opened.
- `nn::fs::EnsureSaveData` (fs_host.c, as `games/by3`).
- The hid debug pad and the touch screen (input.c): not connected, no touches.
- Offline `friends`, `nifm`, `ssl`, network service account and an empty BCAT delivery cache
  (`runtime/system_services.c`, adapted from `games/by3` without its `set` handler, which `settings_service.c` has).
- `bsd:u` converts its session to a CMIF domain: `ipc.c`, `ipc.h` and `runtime_handle_take_session` from `games/by3`.
- **System fonts.** The game hands `GetSharedFontAddress` straight to `nn::fontll::ScalableFontEngine::LoadFont` and
  never calls the engine's `Decode`; with the XOR-encoded BFTTF payload every `LoadFont` returned 403, the font texture
  cache stayed empty and the game read a null glyph (`main+0x8dea04`). `SMO_TRACE_FONT=1` showed the calls and the bytes.
  `shared_font.c` now decodes each verified file in place and rewrites its header with key 0, so the data is plain
  TrueType; `LoadFont` returns 0 for all of them.
- `nn::oe::GetPerformanceConfiguration` before any `Set` (services.c): 0x00020003, the default switchbrew lists for apm.
- The shader translator and SPIRV-Cross in the work folder (`make shader-tools`).
- RomFS directory listing (romfs.c `runtime_romfs_list`, snapshot handles in fs_host.c, from `games/by3`).

Verified: a windowed boot runs 180 s without a stop (killed by the test's timeout) with 10,159 frames presented, 82 NVN
functions and about 580 calls per frame; a screenshot at frame 600 shows the "Try playing with detached Joy-Con" notice
with the Super Mario Odyssey logo, the controller pictures and text in the system font. The audio renderer runs; its
output was silent in that run (rms 0). Screenshots are not committed (game content).

### 2026-10-22: stage 4, into Cap Kingdom

Driven through `TOTK_INPUT_FILE` (key presses) and in-game `shot` commands, which capture the game's frame whatever the
window shows. Answered, in order:

- **The opening scene.** After the airship scene the game sets the screenshot orientation; `nn::oe::SetScreenShotImageOrientation`,
  `Begin/EndBlockingHomeButton` and `IsUserInactivityDetectionTimeExtended` have no Mac counterpart (system_services.c).
  The scene plays with music (audio output rms 0.12 to 0.25, peaks 1.0).
- **H.264 movies through VideoToolbox (movie_host.c).** The 44 play guide movies (`MovieData/*.mp4`: H.264 High profile,
  480x544, 30 fps, B-frames, AAC) went to the SDK's own decoder, which opens NVIDIA's NVDEC (`NvRmChannelOpen` ->
  `NvOsDrvOpen`) and aborted, as TotK's VP9 cutscenes did before its host decoder. Decoder type 1 in buffer mode now runs
  on the host beside the VP9 path: the SPS and PPS come from the format's `avcc` buffer (the 61-byte MP4 avcC record;
  `csd-0` / `csd-1` are absent and the first input is an IDR slice without them), VideoToolbox writes NV12, and a
  reorder buffer of 4 frames hands them over in presentation order (the movies have B-frames); end of stream flushes it.
  Measured: 600 frames at 1.6 ms per frame, no decode errors, the "Throw Cap" movie shows in Cap Kingdom.

Verified: Mario wakes in Cap Kingdom with the HUD (coins, health, map), the "Throw Cap" play guide over it, and walks
forward under the W key; screenshots are not committed (game content).

### 2026-10-22: textures from a uniform block

The first long play session stopped after 30 minutes: fragment shader `bb08dde5…` samples `fp_t_cb3_0`, a texture
whose handle it loads from word 0 of user uniform block c3, not from the driver's handle table c2. The translator gives
such a texture no slot, the reflection load failed and the host aborted. These textures now get texture slots from 120
up, filled at each draw from the uniform block (nvn_refl.m `utex_slot`, nvn_mtl.m `utex_fill`; `make test-utex`).

Measured in the next session: the player got past the place, no abort; the shader's draws read handle 0 there, which the
shader itself treats as "no texture" (it compares `c3[0].xy` with 0 and writes 1.0 instead of the sample). A draw with a
non-zero handle has not been seen yet.

### 2026-10-22: the web page, the applet survey and Horizon's scheduler

- **Offline web page.** After a talk the game opens its own HTML page (`htmlcontents.htdocs/html/<region><language>/index.html`)
  through `nn::web::ShowOfflineHtmlPage`; the SDK's library applet call read a null object. It is now answered as a page
  the player closed (layout of the return value read from the SDK; the game only uses exit reason 3). Measured: the
  next session passed the place, `[smo] web … answered as closed`.
- **Applet survey.** 34 imports of nn::err / swkbd / pctl / nfp / web; the host answered 19, now 24 (VR mode
  restriction, nfp::Unmount); the other 10 are argument setters and getters. The keyboard's config offsets were checked
  against this SDK's setters.
- **A hang after that page.** A worker at priority 45 (mask 0x7) spun at main+0x582bd0 waiting for the audio memory
  pools to detach, without an SVC, on core 1; the audio thread (priority 28) and another (35) may only use core 1 and
  waited for it for minutes while cores 0 and 2 were free (thread dump through the `threads` command). The copy of
  games/totk had taken the TotK build of runtime/threads.c, which preempts only at SVCs. games/totk already solved this for
  Breath of the Wild, which has the same SDK: its build of threads.c follows Horizon (asynchronous preemption by signal
  in guest code, woken threads competing for a core at once, priority inheritance, main thread on its ideal core 0 as
  the npdm says, generation-checked handles). runtime/threads.c is now that build (`unifdef -DGAME_BOTW`) plus
  `runtime_handle_take_session`, and runtime_svc checks for preemption after each SVC as BotW's does. The upstream
  thread probe (`games/totk/tests/system_event_bind`) passes against it.

### 2026-10-22: keys 6 and 7 from upstream (controller type, mouse mode)

- **Input code at upstream daf270e.** gamepad.m, gamepad_layout.h, controller_map.h, motion_fusion.c and the new
  mouse_look.h are upstream's games/totk files as they are (Mario's copies had no changes of their own; this also brings
  generic USB HID pads). frontend.m, input.c and runtime.h took upstream 242acfc (key 6) and 45eecd2 (key 7) by a
  three-way merge and keep Mario's own parts (debug pad and touch screen, three overlay lines, the system overrides).
- **Proof.** tests/test_smo_input.py runs upstream's four input probes against games/smo/tests (layout, controller
  type, mouse look, mouse mode): 4 OK; with the old gamepad.m the controller type and mouse mode probes fail. In the game
  (save copy, Sand Kingdom): key 6 logs `controller type: xbox`, then `playstation`, key 7 `mouse mode on`, and both
  settings land next to the player's controls.txt.

### 2026-10-22: the graphics layer at upstream daf270e (translation chain v7)

- **Ported from upstream e0b24d8..daf270e** the way Q20 did: files Mario never changed are upstream's as they are
  (translator binary, chain v7, shader runtime, overlay, pipeline keys, border probe); hle_nvn.c and nvn_obj.h are
  upstream's resolved with `unifdef -DGAME_BOTW160 -DGAME_BOTW -UGAME_BOTW190 -UTOTK_GAME_V143` (the same flags turn the
  old upstream files into Mario's exactly); nvn_mtl.m, the two shader scripts and the launcher by a three-way merge
  (nvn_mtl.m keeps Mario's uniform textures and the type-view cache fix, 0 conflicts). The seed now translates every
  shader for its default bind state (`all_default`), as Tears of the Kingdom's does; the launcher's GPU budget follows
  the Mac's memory; the overlay has its render pipeline line. The Makefile reads the chain from dmsh_chain.h.
- **Proof.** make runtime builds; 24 of 27 GPU probes pass on the old and the new build alike (the other three need a
  test environment), the border probe with upstream's environment checks 13,818 cases (5,898 before); make test-utex
  passes; 36 Python tests pass; the shared list still reads all 24,110 variants.
