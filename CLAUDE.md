# LiveBilingualCaptions

macOS 26 전용 실시간 양국어 자막 오버레이. 앱 바이너리 배포는 안 한다(서명·공증 없음).
소스는 공개: https://github.com/MOSW626/LiveBilingualCaptions (MIT). 커밋은 `main` 에
쌓고, 기능·수정이 끝나면 push 해서 공개본을 최신으로 유지한다.

## 명령
- **설치: `./install.sh`** → `/Applications` 에 갈아끼운다. 그 뒤로는 Launchpad·Spotlight·
  Finder 에서 여느 앱처럼 연다. 평소 쓰는 경로는 이것이다.
- 빌드+실행(개발용): `./run.sh` → `dist/` 의 것을 띄운다. 설치본과 별개다 —
  **고친 걸 실제로 쓰려면 `./install.sh` 를 돌려야 한다.**
- 빌드만: `./build.sh` → `dist/Live Bilingual Captions.app`
- 테스트: `./test.sh` (**맨 `swift test` 는 실패한다** — swift-testing 경로 플래그 필요)
  **절대 두 번 동시에 돌리지 말 것.** SwiftPM 빌드 락을 두고 서로 막혀서, 테스트가
  200개쯤에서 0% CPU 로 멈춘 채 몇십 분씩 매달린 것처럼 보인다. 코드 결함과 구별이
  안 된다(실제로 두 번 오진했다). 증상이 보이면 `pgrep -f swift-test` 로 중복 프로세스
  부터 확인하고, 있으면 전부 죽인 뒤 하나만 다시 돌린다.
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
- 자동 언어 모드는 분석기·전사기·pump를 언어별로 **두 벌** 돌린다 — 실측 제약으로 `SpeechAnalyzer`
  하나에 `SpeechTranscriber` 둘을 물리면 `setWorkers`에서 SIGTRAP 나므로, "분석기 하나 공유"로
  단순화하면 안 된다(`SpeechPipeline.swift`).
- 세션 중 확정된 전사에서 반복·고유명사 용어를 뽑아(`ContextHintExtractor`) `SpeechAnalyzer.setContext`로
  먹인다 — 기기 안에서 무료이고 켜고 끄는 설정 없이 항상 켜져 있다(인식이 대화가 길어질수록 좋아진다).

## 아이콘
`Resources/AppIcon.icns` (원본 `Resources/AppIcon.png`, 1024px). `build.sh` 가 번들의
`Contents/Resources` 로 복사하고 `Info.plist` 의 `CFBundleIconFile` 이 가리킨다.
바꾸려면 PNG 를 갈아끼우고 `sips` 로 iconset 을 만든 뒤 `iconutil -c icns` 한다.

## 코드서명 인증서 만들기 (1회, 권한 유지용)
ad-hoc 서명은 빌드마다 cdhash 가 바뀌어 마이크·화면기록 권한이 매번 초기화된다.
Keychain Access → 인증서 지원 → 인증서 생성 →
이름 `LiveBilingualCaptions Dev`, 유형 `자체 서명 루트`, 용도 `코드 서명` → 생성.
이후 `build.sh` 가 자동으로 이 인증서를 찾아 쓴다.

## 문서
- 설계: `docs/superpowers/specs/2026-09-16-live-bilingual-captions-design.md`
- 계획: `docs/superpowers/plans/2026-09-16-live-bilingual-captions-rewrite.md`
