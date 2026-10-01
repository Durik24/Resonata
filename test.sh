#!/bin/bash
# Builds and runs Tests/ against the app's logic files.
#   ./test.sh
# Uses plain swiftc, like build.sh, so nothing beyond the command-line tools.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Every app source except the one with `@main`, so the tests can reach the
# views' static helpers too.
SOURCES=$(ls *.swift | grep -v '^ResonataApp.swift$')
swiftc -O -target "$(uname -m)-apple-macos14.0" -o "$OUT/resonata-tests" \
    $SOURCES Tests/*.swift
"$OUT/resonata-tests"
