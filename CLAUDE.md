# LiveBilingualCaptions

macOS 26 전용 실시간 양국어 자막 오버레이. 본인 맥 전용(배포 안 함).

## 명령
- 빌드+실행: `./run.sh`
- 빌드만: `./build.sh` → `dist/Live Bilingual Captions.app`
- 테스트: `./test.sh` (**맨 `swift test` 는 실패한다** — swift-testing 경로 플래그 필요)

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
