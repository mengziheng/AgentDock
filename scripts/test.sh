#!/bin/bash
# Run `swift test`. With only the Command Line Tools installed, point the compiler and
# loader at the Swift Testing framework that ships inside them; Xcode needs no flags.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER="$(xcode-select -p)"
if [[ "$DEVELOPER" == *CommandLineTools* ]]; then
  FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
  LIBRARIES="$DEVELOPER/Library/Developer/usr/lib"
  exec swift test --package-path "$ROOT" \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$LIBRARIES" "$@"
fi
exec swift test --package-path "$ROOT" "$@"
