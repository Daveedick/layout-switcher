#!/bin/bash
set -euo pipefail
layout_switcher_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$layout_switcher_root"
scripts/swiftpm.sh run CoreChecks
