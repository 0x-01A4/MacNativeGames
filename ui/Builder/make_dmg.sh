#!/bin/sh
# A Builder release: build/MacNativeGames-Builder-<version>.dmg, holding the app with this checkout's committed files
# inside it (Contents/Resources/checkout, which Preflight.findRepo finds) and their commit in release.json, which
# build_app.py records in each app it builds in place of git. Signed ad hoc, not notarized: on another Mac, Gatekeeper
# asks before the first start (ui/README.md).
# usage: make_dmg.sh [version]   (default: 0.1-<commit>)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
    echo "make_dmg.sh: commit or stash the local changes first: a release carries exactly one commit" >&2
    exit 1
fi
commit=$(git -C "$repo" rev-parse HEAD)
version=${1:-0.1-$(git -C "$repo" rev-parse --short=8 HEAD)}
case $version in
    *[!0-9A-Za-z.-]* | "") echo "make_dmg.sh: a version is letters, digits, dots and dashes: $version" >&2; exit 1 ;;
esac

stage="$here/build/release"
rm -rf "$stage"
mkdir -p "$stage"
BUILDER_VERSION=$version "$here/make_app.sh" "$stage" >/dev/null
app="$stage/MacNativeGames Builder.app"
sources="$app/Contents/Resources/checkout"
mkdir -p "$sources"
# Committed files only, so nothing the checkout ignores (keys, game files, work folders, built apps) can reach the
# image. games/odyssey is left out: its build compiles inside its own folder, which is sealed in a release.
git -C "$repo" archive --format=tar "$commit" -- . ':(exclude)games/odyssey' | tar -x -C "$sources"
printf '{"schema": 1, "commit": "%s", "version": "%s"}\n' "$commit" "$version" > "$sources/release.json"
found=$(find "$sources" -type f \( -iname '*.keys' -o -iname '*.xci' -o -iname '*.nsp' -o -iname '*.nsz' -o -iname '*.nca' \
    -o -iname '*.xcz' -o -iname '*.bfttf' -o -iname '*.sav' \) | head -5)
if [ -n "$found" ]; then
    echo "make_dmg.sh: keys or game files are committed; refusing to package them:" >&2
    echo "$found" >&2
    exit 1
fi
codesign --force --sign - "$app"   # seals the sources with the app: a changed file stops its signature verifying
codesign --verify --strict "$app"

cp "$repo/LICENSE" "$repo/THIRD_PARTY_NOTICES.md" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="$here/build/MacNativeGames-Builder-$version.dmg"
hdiutil create -quiet -volname "MacNativeGames Builder $version" -srcfolder "$stage" -format UDZO -ov "$dmg"
hdiutil verify -quiet "$dmg"
rm -rf "$stage"
echo "$dmg ($(du -h "$dmg" | cut -f1), commit $commit)"
