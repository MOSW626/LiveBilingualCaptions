#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_name="Live Bilingual Captions"
bundle_dir="$project_dir/dist/$app_name.app"
executable_dir="$bundle_dir/Contents/MacOS"

swift build --package-path "$project_dir" -c release --product LiveBilingualCaptions

mkdir -p "$executable_dir"
cp "$project_dir/Info.plist" "$bundle_dir/Contents/Info.plist"
cp "$project_dir/.build/release/LiveBilingualCaptions" "$executable_dir/LiveBilingualCaptions"

# 권한(TCC)은 코드서명 identity 에 묶인다. ad-hoc(-) 서명은 빌드마다 cdhash 가 바뀌어
# macOS 가 매번 다른 앱으로 보고, 마이크·화면기록 권한을 다시 묻는다.
# 안정적인 자체서명 인증서가 있으면 그것으로 서명해 권한을 유지한다.
identity="LiveBilingualCaptions Dev"
if security find-certificate -c "$identity" >/dev/null 2>&1; then
  codesign --force --sign "$identity" "$bundle_dir"
else
  echo "경고: '$identity' 인증서가 없어 ad-hoc 서명합니다. 빌드마다 권한이 초기화됩니다."
  echo "      해결법은 CLAUDE.md 의 '코드서명 인증서 만들기' 참고."
  codesign --force --sign - "$bundle_dir"
fi

echo "Built: $bundle_dir"
