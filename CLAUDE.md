# LiveBilingualCaptions

macOS 26 전용 실시간 양국어 자막 오버레이. 본인 맥 전용(배포 안 함).

## 명령
- 빌드+실행: `./run.sh`
- 빌드만: `./build.sh` → `dist/Live Bilingual Captions.app`
- 테스트: `./test.sh` (**맨 `swift test` 는 실패한다** — swift-testing 경로 플래그 필요)
- 런치 크래시 확인: `./smoke.sh` — 빌드하고 번들 실행 파일을 직접 띄워 15초 생존을
  확인한다. **유닛 테스트는 실행 시점 액터 격리 트랩(MainActor 클로저가 realtime
  오디오 스레드 등 다른 스레드에서 불려 SIGTRAP 나는 것)을 잡지 못한다** — 프로세스를
  실제로 띄우지 않기 때문이다. 오디오 캡처 콜백, 스레드 전환 배선을 건드렸다면
  `./test.sh` 가 통과해도 반드시 이것도 돌릴 것.
- 지연 측정: `LBC_TIMING=1 "dist/Live Bilingual Captions.app/Contents/MacOS/LiveBilingualCaptions"`
  — 발화별 "오디오 시작 → 첫 부분결과", "첫 부분결과 → 최종" 지연(ms)과 협상된 분석
  포맷을 stderr에 찍는다. 평소엔 완전히 꺼져 있다(환경 변수 미설정 시 비용 없음).

## 환경 제약
- 전체 Xcode 없음 → **XCTest 사용 불가.** swift-testing 전용.
- `swift-tools-version: 6.2` 이상 필수 (`.macOS(.v26)` 때문).
- 서드파티 의존성 없음. 유지한다.

## 구조
- `CaptionsCore` — UI 없는 로직. 테스트는 전부 여기.
- `LiveBilingualCaptions` — AppKit `NSPanel` + SwiftUI 내용.
- 창이 `NSPanel` 인 이유: SwiftUI Scene 으로는 `.screenSaver` borderless 오버레이 불가.

## 코드서명 인증서 만들기 (1회, 권한 유지용)
ad-hoc 서명은 빌드마다 cdhash 가 바뀌어 마이크·화면기록 권한이 매번 초기화된다.
Keychain Access → 인증서 지원 → 인증서 생성 →
이름 `LiveBilingualCaptions Dev`, 유형 `자체 서명 루트`, 용도 `코드 서명` → 생성.
이후 `build.sh` 가 자동으로 이 인증서를 찾아 쓴다.

## 문서
- 설계: `docs/superpowers/specs/2026-09-16-live-bilingual-captions-design.md`
- 계획: `docs/superpowers/plans/2026-09-16-live-bilingual-captions-rewrite.md`
