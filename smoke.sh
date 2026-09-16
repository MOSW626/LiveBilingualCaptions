#!/bin/zsh
set -euo pipefail

# 유닛 테스트는 실행 시점 액터 격리 트랩(예: MainActor 클로저가 realtime 오디오 스레드에서
# 불려 SIGTRAP 나는 것)을 못 본다 — 프로세스를 실제로 띄우지 않기 때문이다. 이 스크립트가
# 그 구멍을 메운다: 빌드하고, 번들 실행 파일을 직접 띄우고, 살아있는지 폴링한다.

project_dir="${0:A:h}"
app_name="Live Bilingual Captions"
binary="$project_dir/dist/$app_name.app/Contents/MacOS/LiveBilingualCaptions"
poll_seconds=15
crash_dir="$HOME/Library/Logs/DiagnosticReports"

echo "1/3 빌드 중..."
"$project_dir/build.sh" >/tmp/smoke_build.log 2>&1 || {
  echo "실패: 빌드가 깨졌습니다. 로그: /tmp/smoke_build.log"
  cat /tmp/smoke_build.log
  exit 1
}

before_crash=$(ls -t "$crash_dir"/LiveBilingualCaptions-*.ips 2>/dev/null | head -1 || true)

pkill -f '/LiveBilingualCaptions$' 2>/dev/null || true
sleep 1

echo "2/3 실행 파일을 직접 띄워 ${poll_seconds}초 동안 생존 확인 중..."
"$binary" >/tmp/smoke_run.log 2>&1 &
pid=$!

cleanup() { kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT

alive=true
for i in $(seq 1 $poll_seconds); do
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    alive=false
    break
  fi
done

if [[ "$alive" == false ]]; then
  echo "실패: 앱이 실행 ${i}초 만에 죽었습니다 (런치 크래시). 로그: /tmp/smoke_run.log"
  cat /tmp/smoke_run.log
  exit 1
fi

echo "3/3 새 크래시 리포트 확인 중..."
after_crash=$(ls -t "$crash_dir"/LiveBilingualCaptions-*.ips 2>/dev/null | head -1 || true)
if [[ -n "$after_crash" && "$after_crash" != "$before_crash" ]]; then
  echo "실패: 프로세스는 살아있지만 새 크래시 리포트가 생겼습니다: $after_crash"
  exit 1
fi

echo "통과: 앱이 ${poll_seconds}초 동안 살아있었고 새 크래시 리포트도 없습니다."
