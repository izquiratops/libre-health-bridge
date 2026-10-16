#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .build/quality-tools
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Pin both the release and archive checksum for reproducible local and CI checks.
install_tool() {
    local repo="$1" version="$2" archive="$3" checksum="$4" binary="$5"
    mkdir -p "$tmp/$binary"
    gh release download "$version" --repo "$repo" --pattern "$archive" --dir "$tmp/$binary"
    (
        cd "$tmp/$binary"
        printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check
        unzip -q "$archive"
    )
    install -m 755 "$tmp/$binary/$binary" ".build/quality-tools/$binary"
}

install_tool nicklockwood/SwiftFormat 0.63.1 swiftformat.zip \
    385ef1a263ba28685157b98c5536b9c9105e124518f28b7ef8a2bee4b167eaeb swiftformat
install_tool realm/SwiftLint 0.65.1 portable_swiftlint.zip \
    c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0 swiftlint
