#!/bin/sh
# Builds build/MacNativeGames Builder.app from Sources/ with swiftc alone (no Xcode project, no SwiftPM) and signs it
# ad hoc. The app finds this checkout by walking up from its own location, so keep it under ui/Builder/build.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/swift_sdk.sh"
app="$here/build/MacNativeGames Builder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
$SWIFTC -O -parse-as-library "$here"/Sources/Core/*.swift "$here"/Sources/App/*.swift -o "$app/Contents/MacOS/MacNativeGamesBuilder"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacNativeGames Builder</string>
    <key>CFBundleIdentifier</key><string>org.macnativegames.builder</string>
    <key>CFBundleExecutable</key><string>MacNativeGamesBuilder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
