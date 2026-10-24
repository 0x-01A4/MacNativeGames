#!/bin/sh
# The Builder's core (events, error text, the runner against Tests/Fixtures/fake_build.py) as one test program: no app,
# no game files.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/swift_sdk.sh"
$SWIFTC "$here"/Sources/Core/*.swift "$here"/Tests/main.swift -o "$probe/builder-tests"
"$probe/builder-tests" "$here/Tests/Fixtures"
