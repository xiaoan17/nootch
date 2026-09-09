#!/bin/sh
# Run tests with the Swift Testing paths omitted by some standalone CLT releases.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_ROOT="$(xcode-select -p)"
TEST_FRAMEWORKS="$DEVELOPER_ROOT/Library/Developer/Frameworks"
TEST_LIBRARIES="$DEVELOPER_ROOT/Library/Developer/usr/lib"

if [ -d "$TEST_FRAMEWORKS/Testing.framework" ] && [ -f "$TEST_LIBRARIES/lib_TestingInterop.dylib" ]; then
    exec swift test --package-path "$ROOT" \
        -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
        -Xlinker -F -Xlinker "$TEST_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" \
        "$@"
fi

exec swift test --package-path "$ROOT" "$@"
