#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_name="Live Bilingual Captions"
bundle_dir="$project_dir/dist/$app_name.app"
executable_dir="$bundle_dir/Contents/MacOS"

mkdir -p "$executable_dir"
cp "$project_dir/Info.plist" "$bundle_dir/Contents/Info.plist"

swiftc -parse-as-library \
  "$project_dir/Sources/LiveBilingualCaptions/main.swift" \
  -o "$executable_dir/LiveBilingualCaptions" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Speech

codesign --force --sign - "$bundle_dir"
echo "Built: $bundle_dir"
