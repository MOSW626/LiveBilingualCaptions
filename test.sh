#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
fw="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
lib="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

# swift-testing 은 CommandLineTools 안에 있지만 SwiftPM 이 자동으로 찾지 못한다.
# -F 는 컴파일·링크용, -rpath 두 개는 런타임 dlopen 용(lib_TestingInterop.dylib 포함).
swift test --package-path "$project_dir" \
  -Xswiftc -F -Xswiftc "$fw" \
  -Xlinker -F -Xlinker "$fw" \
  -Xlinker -rpath -Xlinker "$fw" \
  -Xlinker -rpath -Xlinker "$lib" \
  "$@"
