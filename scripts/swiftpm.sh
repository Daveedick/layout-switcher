#!/bin/bash
set -euo pipefail
layout_switcher_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$layout_switcher_root"
swiftc_path="$(xcrun --find swiftc)"
pm_runtime="$(cd "$(dirname "$swiftc_path")/../lib/swift/pm" && pwd)"
local_pm="$layout_switcher_root/.build/toolchain/pm"
mkdir -p "$local_pm/ManifestAPI/PackageDescription.swiftmodule" "$local_pm/ManifestAPI/CompilerPluginSupport.swiftmodule"
cp "$pm_runtime/ManifestAPI/libPackageDescription.dylib" "$local_pm/ManifestAPI/"
for module in PackageDescription CompilerPluginSupport; do
    for interface in "$pm_runtime/ManifestAPI/$module.swiftmodule/"*.swiftinterface; do
        case "$interface" in *.private.swiftinterface) continue ;; esac
        cp "$interface" "$local_pm/ManifestAPI/$module.swiftmodule/"
    done
done
if [ -d "$pm_runtime/PluginAPI" ] && [ ! -e "$local_pm/PluginAPI" ]; then ln -s "$pm_runtime/PluginAPI" "$local_pm/PluginAPI"; fi
export SWIFTPM_CUSTOM_LIBS_DIR="$local_pm"
export CLANG_MODULE_CACHE_PATH="$layout_switcher_root/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$layout_switcher_root/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
command="${1:?Use build, run, or package as first argument}"
shift
overlay="$(python3 scripts/prepare-toolchain.py)"
case "$command" in
    build|test|run) exec xcrun swift "$command" --disable-sandbox -Xswiftc -vfsoverlay -Xswiftc "$overlay" -Xcc -ivfsoverlay -Xcc "$overlay" "$@" ;;
    *) exec xcrun swift "$command" --disable-sandbox "$@" ;;
esac
