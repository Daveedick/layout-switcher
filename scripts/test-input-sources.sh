#!/bin/bash
set -euo pipefail
layout_switcher_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$layout_switcher_root"

# Compile the real Core module used by InputSources, then link that same code
# into the read-only platform regression executable.
scripts/swiftpm.sh build --target LayoutSwitcherCore
core_bin_dir="$(scripts/swiftpm.sh build --show-bin-path)"
core_objects=("$core_bin_dir/LayoutSwitcherCore.build/"*.swift.o)

output_dir="$layout_switcher_root/.build/PlatformChecks"
module_cache="$layout_switcher_root/.build/PlatformChecks/ModuleCache"
mkdir -p "$output_dir" "$module_cache"
overlay="$(python3 scripts/prepare-toolchain.py)"
binary="$output_dir/InputSourceThreadCheck"

CLANG_MODULE_CACHE_PATH="$module_cache" \
xcrun swiftc -swift-version 5 \
  -vfsoverlay "$overlay" \
  -Xcc -ivfsoverlay -Xcc "$overlay" \
  -module-cache-path "$module_cache" \
  -I "$core_bin_dir/Modules" \
  Sources/LayoutSwitcher/InputSources.swift \
  Tests/PlatformChecks/InputSourceThreadCheck.swift \
  "${core_objects[@]}" \
  -o "$binary"
"$binary"
