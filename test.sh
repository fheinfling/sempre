#!/bin/bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# Swift Testing lives outside the default search paths, so point the compiler at it.
set -euo pipefail
cd "$(dirname "$0")"

FLAGS=()
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* && -d "$F" && -d "$L" ]]; then
  FLAGS=(-Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L")
fi
# ${FLAGS[@]+...} because macOS's bash 3.2 treats an empty array as unbound under set -u
swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
