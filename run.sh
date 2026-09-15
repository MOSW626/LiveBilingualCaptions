#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
"$project_dir/build.sh"
pkill -f '/LiveBilingualCaptions$' 2>/dev/null || true
open -n "$project_dir/dist/Live Bilingual Captions.app"
