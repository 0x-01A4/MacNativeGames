#!/bin/sh
# What the Mac needs before the Builder and build_app.py can run, checked where Sources/Core/Preflight.swift checks it,
# and installed only after asking. `make` runs this before it builds and opens the Builder. The full Xcode and the
# iPhone/iPad tools (xcodegen, cmake, ninja) stay on the Builder's Output page, since only some builds need them.
# usage: setup.sh   (YES=1 installs without asking; BREW_PREFIX=<folder> looks for Homebrew there, a developer option)
set -eu
prefix=${BREW_PREFIX:-/opt/homebrew}

ask() {   # ask "question": true on y/yes; never installs without a terminal to ask on
    [ "${YES:-}" = 1 ] && return 0
    [ -t 0 ] || return 1
    printf '%s [y/N] ' "$1"
    read -r answer || return 1
    case $answer in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

if [ "$(uname -m)" != arm64 ]; then
    echo "setup.sh: MacNativeGames needs a Mac with Apple silicon" >&2
    exit 1
fi
major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$major" -lt 26 ]; then
    echo "setup.sh: MacNativeGames needs macOS 26 or later (this Mac has $(sw_vers -productVersion))" >&2
    exit 1
fi

if [ ! -e /Library/Developer/CommandLineTools/usr/bin/clang ] && [ ! -e /Applications/Xcode.app/Contents/Developer ]; then
    echo "The Xcode command line tools are missing."
    if ask 'Install them with "xcode-select --install"?'; then
        xcode-select --install || true
        echo "Run make again when the installer has finished."
    else
        echo "Install them with: xcode-select --install"
    fi
    exit 1
fi

brew=
for candidate in "$prefix/bin/brew" /usr/local/bin/brew; do
    [ -x "$candidate" ] && { brew=$candidate; break; }
done
python=
for dir in "$prefix/bin" /usr/local/bin; do
    for name in python3.14 python3.15; do
        [ -x "$dir/$name" ] && [ -z "$python" ] && python="$dir/$name"
    done
done
missing=
[ -n "$python" ] || missing="python@3.14"
for package in opus libvpx; do
    [ -d "$prefix/opt/$package/lib" ] || missing="${missing:+$missing }$package"
done
[ -z "$missing" ] && exit 0

echo "Homebrew packages missing: $missing"
if [ -z "$brew" ]; then
    echo "Homebrew isn't installed. Install it from https://brew.sh:"
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo "then run make again."
    exit 1
fi
if ! ask "Install them with \"brew install $missing\"?"; then
    echo "Install them with: brew install $missing"
    exit 1
fi
# shellcheck disable=SC2086 # one word per package
"$brew" install $missing
