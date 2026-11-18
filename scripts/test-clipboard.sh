#!/bin/bash
set -euo pipefail
layout_switcher_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$layout_switcher_root"
output_dir="$layout_switcher_root/.build/PlatformChecks"
module_cache="$output_dir/ClipboardModuleCache"
mkdir -p "$output_dir" "$module_cache"
overlay="$(python3 scripts/prepare-toolchain.py)"
binary="$output_dir/ClipboardReplacementCheck"

CLANG_MODULE_CACHE_PATH="$module_cache" \
xcrun swiftc -swift-version 5 \
    -vfsoverlay "$overlay" \
    -Xcc -ivfsoverlay -Xcc "$overlay" \
    -module-cache-path "$module_cache" \
    Sources/LayoutSwitcher/ClipboardReplacement.swift \
    Tests/PlatformChecks/ClipboardReplacementCheck.swift \
    -framework AppKit \
    -o "$binary"
"$binary"
