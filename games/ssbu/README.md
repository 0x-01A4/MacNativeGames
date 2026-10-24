# Super Mario Odyssey (work in progress)

An experiment: run Super Mario Odyssey natively the way `games/totk` runs Tears of the Kingdom and `games/by3` runs
Bayonetta 3. **It starts and draws its first screen** (the "Try playing with detached Joy-Con" notice, with the game's
logo and the system fonts) and runs its frame loop without a stop for minutes; not played further yet, no sound heard
yet. How the work was done and what was found on the way: [CHANGELOG.md](CHANGELOG.md).

Run (after stage 1 below), from `games/smo`:

```sh
make prepare SHARED_FONTS="<a TotK build>/totk/extracted/firmware/shared-fonts"
make seed shader-libs runtime boot
```

`make shader-libs` compiles the seed's shaders into Metal libraries ahead of time (needs the Metal toolchain:
`xcodebuild -downloadComponent MetalToolchain`), so a new area does not wait for Metal to compile them while it loads.

`make seed` prepares the shaders before the first start, as the Tears of the Kingdom build does: every shader of
`ShaderData/` and `SystemData/` for its default bind state and every variant the shared list `assets/shader_list.tsv`
names (identifiers only, no game data; [docs/shader-list.md](../../docs/shader-list.md)). After playing, `make shader-list`
adds what you met to the list; send it in a pull request so everyone's next build carries it.

Keys as for Tears of the Kingdom: J is A, K is B, WASD the left stick, Return +.

You must own the game: use your own NSPs and the `prod.keys` dumped from your own Switch. Nothing from the game is in
this repository; `SMO_build/` (the work folder) and `mods/` are ignored by git.

## Inputs

- Base `0100000000010000` (v0, 1.0.0) and update 1.4.1 `0100000000010800` (v393216), both NSP.
- The code comes from the update (SDK 7.3.2; the base 1.0.0 is SDK 3.5.1). Every hash is pinned in
  `assets/expected-v1.4.1.json`.

## Stage 1: code and data

From `games/smo`:

```sh
python3.14 -m venv SMO_build/venv && SMO_build/venv/bin/pip install -r requirements.txt
PY=SMO_build/venv/bin/python
$PY scripts/extract_code.py "<update 1.4.1>.nsp" --keys prod.keys --output SMO_build/extracted/v141/exefs
$PY scripts/merge_romfs.py "<base>.nsp" "<update 1.4.1>.nsp" --keys prod.keys --output SMO_build/extracted/v141/romfs
for m in sdk subsdk0 main; do
  DM_RULESET=native DM_PRIVATE_GATES=0 $PY third_party/d2r/patch_nso.py SMO_build/extracted/v141/exefs/$m SMO_build/rewritten/v141 $m
done
$PY scripts/check_expected.py
```

Verifying the rewrite (needs `brew install llvm` for `structck.py`):

```sh
for m in sdk subsdk0 main; do
  $PY third_party/d2r/structck.py SMO_build/rewritten/v141 $m SMO_build/extracted/v141/exefs/$m
  $PY third_party/d2r/equiv.py SMO_build/rewritten/v141 $m SMO_build/extracted/v141/exefs/$m --jobs 8
done
```

| Check | Result |
|---|---|
| ExeFS (main, sdk, subsdk0, rtld, main.npdm) | FS header, hash table and every block verified |
| Merged RomFS (base + BKTR update) | all six IVFC levels: 346,568 data blocks; 4,972 files, 5.68 GB; one flipped byte is caught |
| Rewrite structure (`structck.py`) | OK for all three modules, 0 violations |
| Rewrite semantics (`equiv.py`, random states) | 24,343 sites, 0 divergent; mutation controls: see the changelog |
| Rewrite repeatability | two runs give identical bytes |

## What the game needs (port probe `tools/port_probe.py`, a separate change; against Tears of the Kingdom 1.4.3)

| Part | 1.4.1 |
|---|---|
| NVN | 465 names carried: 383 implemented in the TotK graphics layer, 4 no-ops, 75 known but not implemented, 3 not in `names.txt` |
| SDK functions | 1,186 imported: 98 replaced by the TotK host, 809 TotK also runs natively, 279 unproven (audio, sockets/SSL, BCAT, hid vibration, the nnos C API, 11 NVIDIA driver functions imported directly) |
| Services | 44 in the npdm, all listed by TotK too |
| SVCs | 3 not in TotK: 0x48, 0x49, 0x53 |

These are upper bounds: a name the game carries may never be called.

## Next

Stage 4: get past the first notice with the keyboard or a controller to the title screen and into the first kingdom;
check sound (the audio renderer runs, its output was silent so far) and whether the picture is right.
