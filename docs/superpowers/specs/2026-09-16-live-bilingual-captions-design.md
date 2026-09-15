# Live Bilingual Captions — 재설계 스펙

- 작성일: 2026-09-16
- 상태: 승인된 기본 구조 유지 · 2026-09-16 검토 수정 반영 (아래 구현 검증 항목은 미완료)
- 기준 커밋: `62687c2` (재작성 이전 단일 파일 AppKit 버전)
- 접근안: **C — SwiftUI + SPM 전면 재작성** (사용자 선택. 추천안은 B였으나 C로 확정)

---

## 1. 배경

현재 앱은 `Sources/LiveBilingualCaptions/main.swift` 단일 파일 504줄이다. 동작은 하지만
아래 구조적 문제를 안고 있다.

| 문제 | 위치 (기준 커밋) | 영향 |
|---|---|---|
| `startModernTranscription()` 이 한 번도 호출되지 않음 | 322–397 | 75줄 죽은 코드. macOS 26 엔진이 있는데 안 씀 |
| 비공식 Google `gtx` 번역 엔드포인트 | 465–489 | 차단·레이트리밋 위험. 발화가 매번 외부로 전송됨 |
| 손으로 짠 RMS 음성 감지 (임계값 `0.0035` 하드코딩) | 214–225 | 마이크·환경별 보정 불가 |
| 발화마다 recognizer 재생성하는 언어 휴리스틱 | 281–314 | 문장 중간 자막 초기화, 매직넘버 `0.28` |
| 마이크 입력 전용 | 208–225 | 상태표시줄은 "회의 모드"라고 쓰지만 상대방 말은 못 잡음 |
| 설정 영속 없음 | — | 언어 모드·창 위치·폰트 크기가 매 실행 초기화 |
| 언어 문자열 `"ko"`/`"en"` 이 코드 전역에 산재 | 8곳 | 언어 추가 시 전 파일 수정 |
| 테스트 없음, 버전 관리 없음 | — | 회귀 감지 불가 |

## 2. 목표

1. 마이크와 시스템 오디오를 **전환 가능한 소스**로 지원한다.
2. 인식을 macOS 26 `SpeechAnalyzer` 파이프라인으로 이주해 직접 짠 VAD·재시작 루프를 제거한다.
3. 번역을 **온디바이스 Apple Translation 기본 + LLM 보정 옵션** 2단으로 구성한다.
4. 언어를 테이블로 관리해 한↔영 외 언어를 설정 한 줄로 추가할 수 있게 한다.
5. UI 없는 `CaptionsCore` 라이브러리를 분리해 순수 로직을 테스트 가능하게 한다.

## 3. 비목표 (YAGNI)

- Developer ID 서명·공증·배포. **본인 맥 전용**이므로 자체서명까지만 한다.
- 자막 기록/저장/내보내기. 요청되지 않았다.
- 화자 분리(diarization). 프레임워크가 주지 않고, 요청되지 않았다.
- 한 문장 안의 코드스위칭(한·영 혼용) 인식. §9 리스크 2 참조 — 프레임워크 한계.
- 커스텀 번역 모델·용어집. 3단계 이후 필요해지면 그때 판단한다.

## 4. SDK 사전 확인 (2026-09-16, macOS 26.6.2 / Swift 6.3.3 / MacOSX.sdk 에서 직접 검증)

계획이 기대는 API가 실재하는지 `.swiftinterface` 로 확인한 결과:

| API | 확인 결과 |
|---|---|
| `Speech.SpeechTranscriber` | 존재. `LocaleDependentSpeechModule` — **locale당 인스턴스 1개** |
| `Speech.SpeechDetector` | 존재. `DetectionOptions(sensitivityLevel: .low/.medium/.high)` — 내장 VAD |
| `SpeechAnalyzer.setModules(_:)` | 존재. 오디오 입력을 끊지 않고 모듈 교체 가능 |
| `SpeechAnalyzer.setContext(_:)` | 존재. 문맥 힌트 주입 |
| `TranslationSession.init(installedSource:target:)` | macOS 26.0+ 존재. **SwiftUI 없이 AppKit에서 직접 호출 가능** |
| `LanguageAvailability.status(from:to:)` | 존재. `.installed` / `.supported` / `.unsupported` |
| `_Translation_SwiftUI` 의 `.translationTask(source:target:action:)` | 존재. 언어팩 미설치 시 다운로드 시트 제공 |
| `SCStreamConfiguration.capturesAudio` / `excludesCurrentProcessAudio` | macOS 13.0+ 존재 |
| `SCStreamConfiguration.captureMicrophone` | macOS 15.0+ 존재 (채택하지 않음 — §6.1 참조) |
| `SwiftUI.NSHostingView` | 존재 |

## 5. 구조

```
Package.swift
Sources/
  CaptionsCore/              # 라이브러리. UI 의존 없음 → 테스트 가능
    AudioSource.swift        # AudioSource 프로토콜 + MicSource + SystemAudioSource
    SpeechPipeline.swift     # SpeechAnalyzer + SpeechTranscriber + SpeechDetector
    AudioBufferConverter.swift # 분석기 지원 포맷 변환
    PipelineController.swift # 시작/정지/재구성 직렬화
    LanguageTable.swift      # CaptionLanguage 테이블 + 감지
    Translator.swift         # Apple Translation 1단 + TranslationRefiner 2단
    Settings.swift           # UserDefaults 영속
  LiveBilingualCaptions/     # 실행 파일
    main.swift               # 최상위 AppKit 진입점 (Task 7 이후)
    AppDelegate.swift        # NSPanel 호스팅, LSUIElement, 메뉴바 아이템
    CaptionOverlay.swift     # SwiftUI 자막 뷰 — .translationTask 부착 지점
    SettingsView.swift       # SwiftUI 설정 창
Tests/CaptionsCoreTests/
docs/superpowers/specs/
Info.plist
build.sh                     # swift build 산출물로 .app 번들 조립
run.sh
```

**창은 SwiftUI `Scene`이 아니라 `NSPanel` + `NSHostingView`다.** 순수 SwiftUI Scene으로는
`level = .screenSaver` borderless 오버레이를 만들 수 없다. SwiftUI는 내용만 그리고 창 자체는
AppKit이 잡는다. `.translationTask`는 `NSHostingView` 안의 뷰 계층에서 동작하므로
접근안 C의 이점(언어팩 자동 다운로드 프롬프트)은 그대로 유지된다.

## 6. 컴포넌트

### 6.1 오디오 계층 — `AudioSource.swift`

```swift
@MainActor
protocol AudioSource: AnyObject {
    func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat
    func stop() async
}
```

- **`MicSource`** — `AVAudioEngine` + `installTap`. 기준 커밋의 마이크 코드를 재사용한다.
  필요 권한: 마이크.
- **`SystemAudioSource`** — `SCStream`, `capturesAudio = true`,
  `excludesCurrentProcessAudio = true`. `CMSampleBuffer` → `AVAudioPCMBuffer` 변환 포함.
  필요 권한: 화면 기록.

구현이 둘이므로 프로토콜이 정당하다(1구현 인터페이스가 아니다).

start는 실제 캡처 포맷을 반환하며 분석 포맷 변환은 파이프라인이 담당한다. 콜백이 반환되기
전에 버퍼를 복사·변환한다. 시스템 오디오의 첫 포맷 대기는 선도착 결과를 보관하는 gate를
사용하며 첫 버퍼·시작 실패·취소·정지·제한 시간 중 하나로 정확히 한 번 완료한다.
stop은 실제 캡처 종료를 기다린다. 재시작마다 gate·포맷·실행 토큰을 새로 만든다.

`SCStreamConfiguration.captureMicrophone` 으로 두 소스를 하나의 `SCStream` 으로 합칠 수
있으나 **채택하지 않는다.** 마이크만 쓸 때도 화면 기록 권한을 요구하게 되어 UX가 나빠지고,
재빌드마다 권한이 초기화되는 문제(§9 리스크 1)를 마이크 경로까지 끌고 오기 때문이다.

### 6.2 인식 파이프라인 — `SpeechPipeline.swift`

```swift
SpeechAnalyzer(modules: [
    SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true),
    SpeechTranscriber(locale: currentLocale, preset: .progressiveTranscription)
])
```

기준 커밋에서 **삭제**되는 코드:

| 삭제 대상 | 줄 | 대체 |
|---|---|---|
| RMS 음성 감지 루프 | 214–225 | `SpeechDetector` |
| 무음 타이머 + recognizer 재시작 | 281–292 | 프레임워크가 발화 경계 관리 |
| 언어 휴리스틱 (`0.28` 매직넘버) | 294–314 | 수동 언어 선택 + 실험적 문자열 분류, 호환 포맷에서 모듈 교체 |
| 죽은 `startModernTranscription` | 322–397 | 이것이 본체가 됨 |
| `SFSpeechRecognizer` 경로 전체 | 199–266 | `SpeechTranscriber` |

언어 전환은 새 모듈과 현재 오디오 포맷의 호환성을 확인한 뒤 `setModules()` 로 처리한다.
호환될 때 오디오 탭을 유지한다. 호환되지 않으면 변환기를 재구성하거나 명시적으로 재시작한다.
`setModules()` 자체는 언어를 감지하지 않는다. 현재 locale로 전사한 문자열의 문자 범위만으로
다른 언어의 음성을 신뢰성 있게 감지할 수 없으므로, 자동 모드는 **실험 기능**으로 표시한다.
기본값은 한국어 고정이며 수동 언어 전환을 필수 경로로 검증한다. 독립적인 음성 언어 감지
전략을 검증하기 전에는 한국어↔영어 자동 전환 성공을 보장하거나 완료 조건으로 삼지 않는다.

**오디오 포맷과 수명 관리:** 설치된 모듈의 `bestAvailableAudioFormat`을 조회하고 입력을
`AVAudioConverter`로 변환한 후 `AnalyzerInput`을 만든다. 분석기는 자동 리샘플링하지 않는다.
콜백 버퍼는 캡처 API의 재사용 가능성을 고려해 소유권을 확보하고, 입력 큐는 크기를 제한한다.
시작·정지·소스/언어 전환은 하나의 제어 경로에서 순서대로 처리한다. 정지는 시작 작업을
취소하고 실행 세대를 무효화한다. 각 `await` 이후 세대를 검사하며 실패·취소 시 해당 실행의
소스·분석기·결과 태스크·진행률 태스크를 정리한다. 이전 실행의 정리가 새 실행을 건드리면 안 된다.

파이프라인은 **부분 결과(volatile)** 와 **확정 결과(final)** 를 구분해 방출한다.
이 구분이 번역 2단의 트리거가 된다.

```swift
enum Transcript { case partial(String), final(String) }
```

### 6.3 번역 계층 — `Translator.swift`

2단 구성.

**1단 (항상 동작)** — `TranslationSession` 온디바이스.
`.partial` 이 올 때마다 디바운스 후 번역해 즉시 표시. 지연 거의 없음. 네트워크 불필요.

**2단 (옵션, 기본 꺼짐)** — LLM 보정.

```swift
protocol TranslationRefiner {
    func refine(_ draft: String, source: String, context: [String]) async throws -> String
}
```

`.final` 에만 동작한다. 부분 결과에 붙이면 자막이 깜빡이기 때문이다. 교체 시 크로스페이드한다.
각 번역 요청에는 실행 세대·발화 ID·수정 번호·언어쌍을 연결한다. 새 원문 표시, 지우기,
정지, 언어/소스/대상 변경 시 이전 요청을 무효화한다. 취소를 무시하고 늦게 도착한 응답도
현재 요청과 일치할 때만 표시한다. 같은 문자열을 다시 말한 것은 별개 발화이며 보정 대상이다.
보정 끄기와 키 교체는 진행 중 보정도 무효화한다. 키 저장 성공 직후 보정기를 갱신한다.
모델은 자막의 지연 민감도를 고려해 최저지연 모델(Haiku 4.5)을 쓴다.
**구현 직전에 `claude-api` 스킬을 로드해 모델 ID·파라미터를 확정한다. 기억에 의존하지 않는다.**
API 키는 **Keychain**에 저장한다. 코드·`UserDefaults`·환경변수에 두지 않는다.
2단을 꺼도 앱은 완전히 동작해야 한다.

**언어팩 처리** — `LanguageAvailability.status(from:to:)` 로 분기한다.

| 상태 | 처리 |
|---|---|
| `.installed` | 즉시 번역 |
| `.supported` | `.translationTask` 가 다운로드 시트를 띄움. 완료까지 원문만 표시 |
| `.unsupported` | 해당 언어쌍을 설정 UI에서 비활성화 |

### 6.4 언어 테이블 — `LanguageTable.swift`

```swift
struct CaptionLanguage: Equatable {
    let locale: Locale
    let displayName: String
    let scalarRanges: [ClosedRange<UInt32>]   // 감지용 문자 범위
}
```

기본값 `[ko-KR, en-US]`. 감지·전환·번역 대상 선택이 전부 이 배열만 읽는다.
기준 커밋에서 `"ko"`/`"en"` 문자열이 8곳에 흩어져 있던 것을 여기로 모은다.
언어 정의 추가는 배열 한 줄이며, 실제 사용 가능 여부는 음성 모델·번역 언어쌍 지원 확인을 거친다.
문자열 분류는 `scalarRanges` 로 일반화하므로 한글 전용 하드코딩
(`0xAC00...0xD7A3`, 기준 커밋 297·466줄)이 사라진다.

**문자열 분류 규칙** (음성 언어 감지가 아니다. 라틴 문자 범위는 여러 언어가 공유한다):

1. 각 언어의 `scalarRanges` 에 들어가는 문자 수를 센다.
2. **고유 범위**(그 언어만 갖는 범위, 예: 한글 음절)에 해당하는 문자가 1자라도 있으면
   그 언어로 확정한다. 고유 범위를 가진 언어가 둘 이상 매칭되면 문자 수가 많은 쪽을 택한다.
3. 고유 범위 매칭이 없으면 **공유 범위**(라틴 등)를 가진 언어 중 테이블 순서상 첫 번째를 택한다.
   라틴 문자가 3자 미만이면 판단을 보류하고 현재 언어를 유지한다.
4. 어느 범위에도 안 걸리면 현재 언어를 유지한다.

번역 대상 언어는 "테이블에서 감지된 언어가 아닌 첫 번째 언어"로 정한다.
언어가 3개 이상이면 설정에서 지정한 기본 대상 언어를 쓴다. 기본 대상이 원문 언어와 같으면
테이블의 첫 번째 다른 언어를 택한다. 저장한 대상 ID가 없으면 기본 테이블 순서로 복구한다.
지원 상태는 방향이 있는 언어쌍마다 확인한다. `.unsupported`는 선택 불가, `.supported`는
다운로드 후 사용 가능으로 표시한다. 저장된 미지원 조합은 원문만 표시하고 설정 수정을 안내한다.

### 6.5 설정 — `Settings.swift`

`UserDefaults` 영속 항목: 언어 모드, 기본 번역 대상, 오디오 소스, 창 위치·크기, 폰트 크기,
LLM 보정 on/off, 자막 유지 시간, `SpeechDetector` 민감도.

설정 변경은 이전 값과 비교한 뒤 저장·UI 갱신·필요한 파이프라인 재구성을 한 경로에서 수행한다.
소스·고정 언어·민감도 변경은 실행 중 즉시 적용한다. 중지 중에는 다음 시작에 적용한다.
복원한 창 크기와 위치는 현재 디스플레이의 보이는 영역으로 제한한다.

설정 창은 SwiftUI. `LSUIElement` 앱이므로 메뉴바 상태 아이템에서 연다.

### 6.6 UI — `CaptionOverlay.swift`

기준 커밋의 시각 디자인(HUD 재질, 20pt 원문 / 16pt 번역, 라운드 20, 화면 하단 중앙)을
유지한다. 잘 동작하는 디자인이므로 바꿀 이유가 없다. SwiftUI로 옮기면서 얻는 것:
`.translationTask` 부착 지점, 폰트 크기 동적 반영, 크로스페이드 애니메이션.

## 7. 데이터 흐름

```
AudioSource ──AVAudioPCMBuffer──▶ SpeechPipeline
                                       │
                            .partial / .final
                                       │
                                       ▼
                                  Translator
                          1단: TranslationSession (즉시)
                          2단: TranslationRefiner (final 한정, 옵션)
                                       │
                                       ▼
                              CaptionOverlay (SwiftUI)
```

## 8. 테스트

`CaptionsCore` 가 UI와 분리되어 순수 로직만 테스트한다. `swift-testing` 기본만 쓰고
별도 프레임워크·픽스처를 도입하지 않는다.

| 대상 | 테스트 |
|---|---|
| `LanguageTable` 감지 | 한글/라틴/혼합/빈 문자열 → 기대 언어 |
| 자막 꼬리 자르기 | 92자 경계, 공백 없는 장문, 경계 미만 |
| 번역 디바운스 | 연속 입력 시 호출 횟수 |
| `Settings` 라운드트립 | 저장 → 로드 시 동일 값 |
| `Translator` 2단 | final 한정, 응답 역전, 취소 무시 응답, 지우기/정지 후 응답 폐기, 동일 문장의 별개 발화 |
| 제어 흐름 | 다운로드 중 정지, 연속 소스 전환, 실패 후 재시작, 이전 실행 이벤트 폐기 |
| 시스템 오디오 시작 | 첫 버퍼 선도착, 무음, 시작 실패, 시작 대기 중 정지, 같은 소스 재시작 |
| 설정 적용 | 변경 전후 비교, 소스/언어/민감도 적용, 키 저장 직후 연결, 대상/창 크기 복원 |

실제 오디오 캡처·음성 인식은 단계별 수동 스모크로 검증한다. 포맷 변환은 합성 PCM으로,
시작/정지 경합과 비동기 응답 순서는 가짜 소스·명시적으로 재개하는 continuation으로 검증한다.
단순 sleep 시간을 늘려 테스트 실패를 숨기지 않는다.

## 9. 리스크

1. **재빌드마다 권한 초기화.** 현재 `codesign --force --sign -` (ad-hoc)이라 빌드마다
   cdhash가 바뀌고 macOS가 다른 앱으로 인식한다. 마이크는 감수할 만하나 화면 기록 권한은
   5단계 작업을 크게 방해한다.
   → **완화**: 1단계에서 Keychain에 안정적인 자체서명 코드서명 인증서를 만들어 그것으로 서명한다.

2. **`SpeechTranscriber` 는 locale당 1개.** 한 문장 안에 한국어와 영어가 섞이면 여전히
   한쪽만 인식한다. `setModules()` 는 전환을 싸게 만들 뿐 코드스위칭을 해결하지 않는다.
   → **완화 없음.** 기대치를 여기에 맞춘다. 비목표(§3)에 명시했다.

3. **LLM 보정이 자막을 깜빡이게 할 위험.** `.final` 한정 + 크로스페이드로 완화하되,
   실사용에서 거슬리면 **7단계를 폐기한다.** 옵션이고 기본 꺼짐이므로 폐기 비용이 없다.

4. **음성 모델 최초 다운로드 지연.** `AssetInventory.assetInstallationRequest` 진행률을
   자막 자리에 표시한다(기준 커밋 335–348줄의 방식을 유지).

5. **SPM 실행 파일로 .app 번들 만들기.** `swift build` 는 `.app` 을 만들지 않는다.
   → `build.sh` 가 지금처럼 번들 디렉터리를 직접 조립하고 `Info.plist` 를 복사한다.
   `NSMicrophoneUsageDescription` 등 usage description 이 번들 `Info.plist` 에 있어야
   권한 프롬프트가 뜬다.

## 10. 단계

각 단계는 **독립적으로 실행 가능한 앱**을 남긴다. 2단계에서 멈춰도 쓸 수 있어야 한다.

| 단계 | 내용 | 통과 기준 |
|---|---|---|
| 0 | `git init` + 초기 커밋(**완료: `62687c2`**), 프로젝트 `CLAUDE.md` 작성, agent_manager `PROJECTS.md` 등록 | 세 항목 모두 존재. 현재 git init 만 완료 |
| 1 | SPM 전환, 타깃 분리, `build.sh` 개편, 자체서명 인증서 | 실행 타깃은 임시 Swift 5 모드로 기존 기능 유지, Core는 Swift 6 |
| 2 | 인식 엔진 교체 (`SpeechAnalyzer`) | 고정 한국어/영어 및 수동 전환, 입력 포맷 변환, 시작 취소 검증 |
| 3 | 번역 1단 교체 (Apple Translation), Google 제거 | 네트워크 끄고도 번역 동작 |
| 4 | SwiftUI 뷰 이주, `.translationTask` 부착, 실행 타깃 Swift 6 전환 | 동시성 빌드 통과, 언어팩 미설치 시 다운로드 시트 표시 |
| 5 | `SystemAudioSource` + 소스 전환 UI | Zoom/YouTube 소리가 자막으로 출력 |
| 6 | 설정 영속 + 설정 창 + 언어 테이블 확장 | 설정 즉시 적용·재실행 복원, 추가 언어의 지원 상태 검증 |
| 7 | LLM 보정 (옵션, Keychain) | 꺼도 앱이 완전히 동작 |

## 11. 결정 기록

| 결정 | 근거 |
|---|---|
| 접근안 C (전면 재작성) | 사용자 선택. 추천은 B(엔진 교체 + 모듈 분리)였음 |
| C에 B의 엔진 교체를 포함 | `SFSpeechRecognizer` 를 유지한 재작성은 재작성할 값이 없음 |
| 창은 `NSPanel`, 내용만 SwiftUI | SwiftUI Scene 으로 `.screenSaver` borderless 오버레이 불가 |
| 오디오 소스 2구현 분리 | 마이크 전용 사용 시 화면 기록 권한 회피 |
| 번역 2단, LLM은 `.final` 한정·기본 꺼짐 | 자막 깜빡임 방지, 오프라인 동작 보장 |
| 서명은 자체서명까지 | 본인 맥 전용. Developer ID·공증은 비목표 |
