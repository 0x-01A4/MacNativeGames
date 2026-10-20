# Translation and dub mods

Fan translations (text, and sometimes voice) load as player RomFS mods (see "Mods" in the README). This page is what
it took to run one on a Mac: a Brazilian Portuguese text and voice mod for 1.2.1, 1,410 files, on a MacBook Air M1
(2026-10-19). Nothing here ships game content; get the mod from the people who made it.

## 1. The mod must match the app's version

A translation is made for one game version, and its file names say which. In the RomFS, `Mals/<language>.Product.<n>.sarc.zs`
holds the text and `System/Resource/ResourceSizeTable.Product.<n>.rsizetable.zs` the size table: `100` is 1.0.0, `121` is
1.2.1 (1.2.1 keeps its UI archives as `Common.Product.110` and `Title.Product.110`). A 1.2.1 mod in a 1.0.0 app changes no
text (the 1.0.0 game reads `Product.100`), and its voice files paired with another version's size table may not work. Build
the app for the mod's version (`--update` with that update) and put the mod in `mods/<that version>`, for example
`mods/v121`.

## 2. Install

Copy the mod's `romfs` contents (the folders `Mals`, `UI`, `Voice`, `Sound`, ...) into the mods folder, then write the
manifest:

```
python3 games/totk/scripts/make_mod_manifest.py ~/Library/Application\ Support/MacNativeGames/TOTK/mods/v121 \
    --app "Tears of the Kingdom.app"
```

Files the RomFS lacks are added as new files; a path that differs from the game's only in case stops the tool. Some mods also ship an
uncompressed copy of an archive next to the `.zs` (for example `Common.Product.110.Nin_NX_NVN.blarc`). The game reads
the `.zs`; the extra copy would only be added as a new file, so it can be left out.

## 3. Pick the language the mod replaces

A translation usually replaces one of the game's languages, most often American English (`USen`: text in
`Mals/USen...`, voice in `Voice/Resource/USen`). The game follows the Mac's language, so unless the Mac is set to the language
the mod replaces, the mod's text does not show. Give only this game the replaced language:

```
defaults write org.macnativegames.totk AppleLanguages -array en-US
```

`defaults delete org.macnativegames.totk AppleLanguages` goes back to the Mac's language. Started from Terminal,
`TOTK_LANG=en-US` does the same for one run.

## 4. The UI archive and the build's own patch

Most translations also replace `UI/LayoutArchive/Common.Product.<n>.Nin_NX_NVN.blarc.zs` (the UI textures with words
in them). The build's RomFS patch (`make_romfs_patches.py`, the quick-menu capture timing) replaces the same archive,
and two overlays may not replace one file, so the game stops at start with "two overlays replace the same file".
Until that is handled (#73), there are two ways:

- leave the archive out of the mod: everything else is translated, the UI images stay in the original language;
- or merge the two: in 1.2.1 the mod changes only `timg/__Combined.bntx` and the patch only the two `anim/*.bflan`
  members, so the mod's archive with the patch's two members put in (recompressed with the same zstd dictionary)
  carries both, and it goes in place of the build's patch file (and its manifest line) before the app is packaged.

## 5. Check

The log (`~/Library/Logs/MacNativeGames/totk.log`) lists the mod at start:

```
RomFS overlay: 1410 files from .../mods/v121 (1394 more not listed)
RomFS overlay: .../mods/v121 checked, 1410 files, 144.5 MB hashed in 0.69 s
```

A version or hash mismatch stops the start with the file named in the log, so a wrong mod never loads half-way.
