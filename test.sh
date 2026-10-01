#!/bin/bash
# Builds and runs Tests/ against the app's logic files.
#   ./test.sh
# Uses plain swiftc, like build.sh, so nothing beyond the command-line tools.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -O -target "$(uname -m)-apple-macos14.0" -o "$OUT/resonata-tests" \
    AudioSpectrum.swift Lyrics.swift MediaRemote.swift NowPlaying.swift Tests/*.swift
"$OUT/resonata-tests"
