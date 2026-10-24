# Sourced by make_app.sh and run_tests.sh: SDK= the newest macOS SDK this swiftc can build SwiftUI against. A command line
# tools update can install an SDK newer than its compiler ("this SDK is not supported by the compiler"), so the default
# SDK is tried first and then the others, newest first.
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
echo 'import SwiftUI' > "$probe/probe.swift"
SDK=
for candidate in "$(xcrun --show-sdk-path 2>/dev/null)" \
        $(ls -d "$(xcode-select -p)"/SDKs/MacOSX2*.sdk "$(xcode-select -p)"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX2*.sdk 2>/dev/null | sort -rV); do
    [ -d "$candidate" ] || continue
    if swiftc -sdk "$candidate" -target arm64-apple-macos26.0 -typecheck "$probe/probe.swift" 2>/dev/null; then
        SDK=$candidate
        break
    fi
done
if [ -z "$SDK" ]; then
    echo "no macOS 26 SDK that $(swiftc --version 2>&1 | head -1) can use; install Xcode 26 or the matching command line tools" >&2
    exit 1
fi
SWIFTC="swiftc -sdk $SDK -target arm64-apple-macos26.0 -swift-version 5"
