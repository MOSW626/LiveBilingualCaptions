#!/bin/zsh
# 빌드해서 /Applications 에 설치한다. 이걸 돌린 뒤에는 Launchpad·Spotlight·Finder 에서
# 여느 앱처럼 열면 된다 — 더 이상 run.sh 가 필요 없다.
set -euo pipefail

project_dir="${0:A:h}"
app_name="Live Bilingual Captions"
built="$project_dir/dist/$app_name.app"
installed="/Applications/$app_name.app"

"$project_dir/build.sh"

# 실행 중이면 먼저 내린다 — 실행 파일을 갈아끼우는 중에 붙잡혀 있으면 안 된다.
if pgrep -f "/$app_name.app/Contents/MacOS/" >/dev/null 2>&1; then
  echo "실행 중인 앱을 종료합니다…"
  pkill -f "/$app_name.app/Contents/MacOS/" || true
  sleep 1
fi

# 통째로 갈아끼운다. 남은 옛 파일이 섞이면 서명이 깨진다.
rm -rf "$installed"
cp -R "$built" "$installed"

# 서명이 온전한지 확인한다. 깨진 채 설치하면 권한이 매번 초기화되고 원인도 안 보인다.
codesign --verify --strict "$installed"
authority=$(codesign -dvvv "$installed" 2>&1 | sed -n 's/^Authority=//p' | head -1)
echo "설치 완료: $installed"
echo "서명: ${authority:-ad-hoc (권한이 빌드마다 초기화됩니다)}"

# Finder·Spotlight 가 새 아이콘과 새 버전을 바로 집게 한다.
touch "$installed"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$installed" 2>/dev/null || true
