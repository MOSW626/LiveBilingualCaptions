#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_name="Live Bilingual Captions"
bundle_dir="$project_dir/dist/$app_name.app"
executable_dir="$bundle_dir/Contents/MacOS"
resources_dir="$bundle_dir/Contents/Resources"

# CLT 27(2026-10-18 설치) 이후 두 가지가 깨졌다. 기본 빌드 시스템(swiftbuild)은
# "Unknown error parsing property list" 로 시작도 못 하고, macOS 27 SDK 는 SwiftUI @State 를
# 매크로로 바꿨는데 그 플러그인(SwiftUIMacros)은 전체 Xcode 에만 있다.
# ponytail: native 빌드 시스템 + 26.5 SDK 로 고정. native 가 제거되거나 26.5 SDK 가 사라지면 다시 본다.
build_flags=(--build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)

swift build --package-path "$project_dir" "${build_flags[@]}" -c release --product LiveBilingualCaptions

mkdir -p "$executable_dir" "$resources_dir"
cp "$project_dir/Info.plist" "$bundle_dir/Contents/Info.plist"
cp "$project_dir/.build/release/LiveBilingualCaptions" "$executable_dir/LiveBilingualCaptions"
cp "$project_dir/Resources/AppIcon.icns" "$resources_dir/AppIcon.icns"

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
