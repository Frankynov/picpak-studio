#!/bin/bash
# Headless checks: renders every template, proves the exported bytes are on-gamut,
# and round-trips projects through both .picpak and the PNG's embedded chunk.
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d)
SRC=()
while IFS= read -r f; do SRC+=("$f"); done < <(find Sources -name '*.swift' ! -name 'App.swift')
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14 -swift-version 6 \
  -o "$OUT/checks" "${SRC[@]}" Tools/Checks/main.swift
"$OUT/checks"
