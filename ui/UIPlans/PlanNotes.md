# Review of `ui/UIPlans/ui-plan.md`

The plan is a good outline. It has the right constraints, and it flags many open questions itself. This review reads it against `CLAUDE.md` and does not draw on `build_app.py`, so claims about the script's behavior are unverified.

## Gaps, most serious first

1. **Signing and distribution of the UI app itself.**
   - The plan never says how players get the Builder. Options include a notarized DMG, Homebrew, or building from source.
   - The runtime build step "compiles the runtime and packages/signs a `.app`", so it needs a compiler. The plan's toolchain failure class mentions this only briefly.
   - A dev will ask what the Builder requires on the machine: Xcode command line tools, Python 3.14, and the pinned hactool, which is built locally.
   - A sandboxed, notarized Builder can't easily spawn `cc` or `codesign`. This choice constrains the whole technology decision in section 3.

2. **Python 3.14 handling.** The question is asked, but the plan doesn't recommend an answer.
   - Bundling is heavy.
   - Detection plus guided install fails for non-technical users.
   - A dev needs the default, plus a story for pip dependencies such as zstd, which comes from the standard library.

3. **The contract between the UI and `build_app.py`.**
   - `--json-progress` is mentioned, but it's missing three things:
     - the event schema (stages, percent, warnings, structured error codes);
     - cancellation (what SIGTERM does to a half-written `TOTK_build/` work folder);
     - exit codes.
   - The six UI steps in section 4 name different stages from the pipeline in `CLAUDE.md` (shader seed generation, hactool build, IVFC verify). Nobody has said which stage names are authoritative.
   - Changing `build_app.py` is Phase 0 work, but the plan says nothing about keeping its CLI behavior unchanged.

4. **Detection before building.** Step 1 says "detect game and version automatically", but `build_app.py` only does this during the build.
   - A dev will ask if there is a dry-run or `--inspect` mode.
   - Detection needs keys, because it decrypts the NCAs. That means Step 3 (Keys) has to come before Step 1, or the order has to change.
   - The NPDM ACID signature path (a different genuine dump) needs its own UX: the user should see "accepted via signature, not an exact hash match".

5. **Which games and versions are supported.**
   - Phase 1 is "TOTK on the Mac". The plan doesn't say how the UI learns the supported matrix (TOTK v143…, BotW 1.6.0/1.9.0) or Bayonetta 3's status.
   - Bayonetta 3 has a separate Makefile and a manual step-by-step build, and its code is a full copy. The plan should say whether the UI will drive it, hide it, or mark it as experimental.
   - The plan should read the matrix from `games/<game>/assets/expected-v*.json` rather than duplicating it.

6. **Security and privacy of keys and game files.**
   - The question about remembering the keys path is there, but it doesn't cover:
     - whether the log ever echoes key material or file paths;
     - what "copy full log" includes;
     - macOS sandbox and security-scoped bookmarks if the UI is sandboxed.
   - It also doesn't say whether the UI may read keys itself for early validation. That seems to conflict with "never reimplements decryption" unless the validation is delegated to the script.

7. **Shader contribution.** The plan assumes the contribution flow ("Send / Submit automatically", "rows pending") can be controlled from outside the game.
   - The project's rule is that diagnostics and experiments stay off by default.
   - A dev needs to know where the state lives (`shader-list-contribution.txt`, in the app container?), where it's submitted to, and the privacy and consent wording.
   - The plan should say whether it's opt-in, and what data leaves the machine.

8. **How settings reach the game.** Hotkeys 2–7 and env vars like `TOTK_HUD` exist today.
   - If settings are launch-time only, the Launcher has to start the app with env vars, which breaks when the user launches from Finder.
   - The other route is an "input-file command", which `CLAUDE.md` mentions. The plan should pick one and say where it persists: a plist, a JSON file, or the app bundle.
   - Option availability per game and version should come from a manifest, not hardcoded UI.

9. **Rebuild detection and app provenance.** The Launcher lists apps "with game, version, platform and build date", but nothing records that metadata.
   - Probably the build should write a small manifest into the `.app`: repo commit, game version, inputs hash and date.
   - Without it, "detect repo changed and offer rebuild" can't work, and it won't find apps built outside the UI.

10. **iOS.**
    - A sideload explanation (AltStore, Sideloadly, a developer certificate) is a support burden that needs an owner.
    - The plan should say what the UI does when `ipa` output is unsigned, and what the shader-reminder agent is (it's mentioned only in a Q).

## Smaller things a dev will ask

- **Disk and time.** The build needs lots of space (the `TOTK_build/` work folder) and takes a long time. Should the UI preflight free space and warn about duration?
- **Work folder location.** It's "next to the game file". Is that acceptable when the game sits on an external or read-only drive?
- **Concurrent builds, resume and quit.** What happens if the UI is closed mid-build? Does the pipeline resume from stages that already finished?
- **Drag and drop.** Which file types does the UI accept? `.xci`, `.nsp`, `.nsz`, a folder of firmware?
- **Updates to the Builder.** How does it learn that the repo, runtime or translator prebuilt has changed? The prebuilt has a SHA-256 check.
- **Anti-piracy messaging.** The README and project wording matter. The plan should say which user-facing text explains "supply your own".
- **Error taxonomy source.** The list of failure classes comes from guesses. A dev will want a list generated from the real error messages in `build_app.py`.
- **Version compatibility.** Does the UI check it is paired with the matching `build_app.py` revision?

## Structural suggestions

- Add an **architecture section** (UI to script contract, where data is stored, what runs with what privileges). Right now it's implicit in section 3.
- Make **decisions, not just questions**. Most Qs have an obvious default. A shorter "Decided / Open" split would let a dev start, for example:
  - Mac only
  - SwiftUI
  - Builder first
  - wizard
  - stock macOS look
  - launch-time settings
  - UI in `ui/`
- Add **non-goals**: no in-game overlay, no game content or cover art, no emulator-style features.
- Phase 0 should include a **spike**: run `build_app.py` from a Swift `Process`, parse its output, and handle cancel. It would settle the technology question quickly.
- The testing section should add a **fixture strategy**: recorded logs from real failures, with game paths scrubbed so no content leaks into the repo.
- Add an **accessibility and localization baseline** at Phase 1, not Phase 5. Retrofitting strings is expensive.
- `CLAUDE.md` says changes must say what was built and played. Add a **definition of done** for each phase.
