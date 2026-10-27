#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
fw="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
lib="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

# swift-testing 은 CommandLineTools 안에 있지만 SwiftPM 이 자동으로 찾지 못한다.
# -F 는 컴파일·링크용, -rpath 두 개는 런타임 dlopen 용(lib_TestingInterop.dylib 포함).
# CLT 27(2026-10-18 설치) 이후 두 가지가 깨졌다. 기본 빌드 시스템(swiftbuild)은
# "Unknown error parsing property list" 로 시작도 못 하고, macOS 27 SDK 는 SwiftUI @State 를
# 매크로로 바꿨는데 그 플러그인(SwiftUIMacros)은 전체 Xcode 에만 있다.
# ponytail: native 빌드 시스템 + 26.5 SDK 로 고정. native 가 제거되거나 26.5 SDK 가 사라지면 다시 본다.
build_flags=(--build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)

swift test --package-path "$project_dir" "${build_flags[@]}" \
  -Xswiftc -F -Xswiftc "$fw" \
  -Xlinker -F -Xlinker "$fw" \
  -Xlinker -rpath -Xlinker "$fw" \
  -Xlinker -rpath -Xlinker "$lib" \
  "$@"
