#!/bin/bash
# Runs the test suite with code coverage, writes coverage.lcov (for Codecov) and prints a summary.
# Only Sources/ is counted; tests and build products are left out.
set -euo pipefail
cd "$(dirname "$0")/.."

./test.sh --enable-code-coverage
PROF="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
# The test bundle is SempreCoreTests.xctest or SempreCorePackageTests.xctest, depending on the SwiftPM version.
BUNDLE="$(find "$(swift build --show-bin-path)" -maxdepth 1 -name '*.xctest' | head -1)"
BIN="$BUNDLE/Contents/MacOS/$(basename "$BUNDLE" .xctest)"
IGNORE='(\.build|Tests)/'

xcrun llvm-cov export -format=lcov -instr-profile "$PROF" -ignore-filename-regex "$IGNORE" "$BIN" > coverage.lcov
xcrun llvm-cov report -instr-profile "$PROF" -ignore-filename-regex "$IGNORE" "$BIN"
