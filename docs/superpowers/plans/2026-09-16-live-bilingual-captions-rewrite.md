# Live Bilingual Captions 재작성 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 단일 파일 AppKit 자막 앱을, 마이크·시스템 오디오를 전환하며 macOS 26 온디바이스 인식·번역으로 양국어 자막을 띄우는 SPM 기반 SwiftUI 앱으로 재작성한다.

**Architecture:** `CaptionsCore`(UI 없는 라이브러리, 테스트 대상)와 `LiveBilingualCaptions`(실행 파일) 2타깃. 오디오는 `AudioSource` 프로토콜의 두 구현(마이크 / 시스템 오디오)이 `AVAudioPCMBuffer`를 흘려보내고, `SpeechAnalyzer` 파이프라인이 부분/확정 전사로 바꾸고, `Translator`가 온디바이스 번역(+옵션 LLM 보정)을 붙여, `NSPanel` 안의 SwiftUI 뷰가 그린다.

**Tech Stack:** Swift 6.3 / SwiftPM (tools-version 6.2) / macOS 26 / Speech(`SpeechAnalyzer`·`SpeechTranscriber`·`SpeechDetector`) / Translation(`TranslationSession`·`.translationTask`) / ScreenCaptureKit / AppKit + SwiftUI(`NSHostingView`) / swift-testing

**Spec:** `docs/superpowers/specs/2026-09-16-live-bilingual-captions-design.md`

**검토 수정 (2026-09-16):** Swift 언어 모드, 오디오 변환·수명 관리, 시스템 오디오 시작 경합,
번역 응답 순서, 자동 언어 전환의 한계, 설정 적용·키 갱신·스펙 누락을 반영했다.
문서의 코드 예시는 구현 출발점이다. API 존재 확인과 앱 통합 검증을 구분하며,
아래 체크박스를 실행하기 전에는 빌드·런타임 검증이 완료됐다고 보고하지 않는다.

---

## Global Constraints

이 절의 요구사항은 **모든 태스크에 암묵적으로 포함된다.**

- **최소 OS**: macOS 26.0. `Package.swift` 는 `platforms: [.macOS(.v26)]`, `Info.plist` 는 `LSMinimumSystemVersion` `26.0`.
- **swift-tools-version**: `6.2` 이상. `6.0` 으로는 `.macOS(.v26)` 이 `'v26' is unavailable` 로 실패한다 (2026-09-16 실측).
- **테스트 프레임워크**: **swift-testing 전용** (`import Testing`, `@Test`, `#expect`). 이 머신에 전체 Xcode 가 없어 **XCTest 를 쓸 수 없다.** `import XCTest` 는 `no such module` 로 실패한다.
- **테스트 실행은 반드시 `./test.sh`** 로 한다. 맨 `swift test` 는 `no such module 'Testing'` 으로 실패한다 (Task 1 에서 만든다).
- **새 서드파티 의존성 추가 금지.** `Package.swift` 의 `dependencies` 는 빈 배열을 유지한다. 필요한 것은 전부 시스템 프레임워크에 있다.
- **`SpeechTranscriber.TranscriptionOption` 에는 `.punctuation` 이 없다.** 케이스는 `etiquetteReplacements` 하나뿐이다. 구두점은 `preset: .progressiveTranscription` 에서 온다. (`.punctuation` 은 `DictationTranscriber` 의 별개 enum 이다 — 기준 커밋 322–397줄의 죽은 코드를 그대로 옮기면 컴파일이 깨진다.)
- **API 키를 `UserDefaults`·소스코드·환경변수에 두지 않는다.** Keychain 만 쓴다 (Task 10).
- **설치된 모델로 번역·인식은 오프라인 동작해야 한다.** 최초 음성/번역 모델 다운로드와 Task 10의 옵션 보정은 네트워크를 사용한다.
- **자동 인식 언어는 실험 기능이다.** 기본값은 한국어 고정. 문자열의 문자 범위 분류를 음성 언어 감지로 간주하지 않는다.
- **제어 흐름은 한 곳에서 관리한다.** 시작·정지·소스/언어/민감도 변경은 직렬화하고, 취소와 실행 세대 검사를 함께 쓴다.
- **원문 갱신과 번역 무효화는 동기적으로 함께 수행한다.** 이전 번역·보정 응답은 새 자막에 표시하지 않는다.
- **모든 사용자 노출 문자열은 한국어.** 기준 커밋의 문구 톤을 따른다.
- **각 태스크 종료 시 앱이 빌드되고 실행돼야 한다.** 중간에 멈춰도 쓸 수 있는 상태를 남긴다.

### 검증된 API 시그니처 (2026-09-16, 실제 typecheck 통과)

아래는 최초 작성 시 확인한 API 호출 형태다. 전체 예제의 Swift 6 동시성 안전성이나
실제 장치 동작을 보증하지 않는다. 각 태스크에서 해당 타깃의 언어 모드로 다시 빌드한다.

```swift
let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await req.downloadAndInstall()          // req.progress: Progress
}
_ = try await AssetInventory.reserve(locale: locale)
let analyzer = SpeechAnalyzer(modules: [detector, transcriber])
try await analyzer.setModules([detector, newTranscriber])   // 오디오 끊지 않고 언어 교체
for try await r in transcriber.results {
    let s = String(r.text.characters)           // r.text: AttributedString
    _ = r.isFinal                               // SpeechModuleResult 확장 프로퍼티
}

let status = await LanguageAvailability().status(from: Locale.Language(identifier: "ko"),
                                                 to: Locale.Language(identifier: "en"))
// .installed / .supported / .unsupported
let session = TranslationSession(installedSource: Locale.Language(identifier: "ko"),
                                 target: Locale.Language(identifier: "en"))
let out = try await session.translate("안녕하세요").targetText

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
let cfg = SCStreamConfiguration()
cfg.capturesAudio = true
cfg.excludesCurrentProcessAudio = true
let filter = SCContentFilter(display: content.displays[0], excludingWindows: [])
let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
```

---

## File Structure

| 파일 | 책임 |
|---|---|
| `Package.swift` | 2타깃 + 테스트 타깃 정의 |
| `test.sh` | swift-testing 프레임워크 경로를 넣어 `swift test` 실행 |
| `build.sh` | `swift build` 산출물로 `.app` 번들 조립 + 서명 |
| `run.sh` | 빌드 후 실행 |
| `Sources/CaptionsCore/LanguageTable.swift` | 언어 테이블 + 감지 규칙 |
| `Sources/CaptionsCore/CaptionText.swift` | 자막 문자열 가공 (꼬리 자르기) |
| `Sources/CaptionsCore/Settings.swift` | 설정 모델 + UserDefaults 영속 |
| `Sources/CaptionsCore/Transcript.swift` | 부분/확정 전사 타입 |
| `Sources/CaptionsCore/AudioSource.swift` | `AudioSource` 프로토콜 + `MicSource` |
| `Sources/CaptionsCore/SystemAudioSource.swift` | ScreenCaptureKit 시스템 오디오 |
| `Sources/CaptionsCore/SpeechPipeline.swift` | SpeechAnalyzer 구동, 언어 교체 |
| `Sources/CaptionsCore/AudioBufferConverter.swift` | 분석기 지원 포맷으로 PCM 변환 |
| `Sources/CaptionsCore/PipelineController.swift` | 실행 세대·시작/정지/재구성 직렬화 |
| `Sources/CaptionsCore/Translator.swift` | 온디바이스 번역 + `TranslationRefiner` 훅 |
| `Sources/CaptionsCore/ClaudeRefiner.swift` | LLM 보정 구현 (옵션) |
| `Sources/CaptionsCore/KeychainStore.swift` | API 키 보관 |
| `Sources/LiveBilingualCaptions/main.swift` | Task 7 이후 최상위 AppKit 진입점 |
| `Sources/LiveBilingualCaptions/AppDelegate.swift` | NSPanel, 메뉴바 아이템, 파이프라인 배선 |
| `Sources/LiveBilingualCaptions/CaptionOverlay.swift` | SwiftUI 자막 뷰, `.translationTask` |
| `Sources/LiveBilingualCaptions/CaptionState.swift` | `@Observable` UI 상태 |
| `Sources/LiveBilingualCaptions/SettingsView.swift` | SwiftUI 설정 창 |
| `Tests/CaptionsCoreTests/*.swift` | 순수 로직 테스트 |

---

# Task 1: SPM 전환 + 테스트 하네스 + 번들 빌드

기존 동작을 유지하면서 빌드 체계를 바꾼다. 기존 실행 타깃은 임시로 Swift 5 언어 모드를
명시한다. Swift 6 컴파일러 사용과 Swift 6 언어 모드 채택은 별개다. Core는 처음부터 Swift 6,
실행 타깃은 Task 7에서 동시성 정리 후 Swift 6으로 전환한다.

**Files:**
- Create: `Package.swift`, `test.sh`, `Tests/CaptionsCoreTests/SmokeTests.swift`, `Sources/CaptionsCore/CaptionsCore.swift`, `CLAUDE.md`
- Modify: `build.sh` (전체 교체), `Info.plist` (`LSMinimumSystemVersion`)
- Modify: `Sources/LiveBilingualCaptions/main.swift` (기존 `@main` 구조의 SPM 빌드 확인; 필요 시 진입점 파일 이름 분리)

**Interfaces:**
- Consumes: 없음
- Produces: `./test.sh` (테스트 실행 명령), `./build.sh` (번들 빌드), `CaptionsCore` 모듈 (빈 상태)

- [ ] **Step 1: `Package.swift` 작성**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiveBilingualCaptions",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CaptionsCore"),
        .executableTarget(
            name: "LiveBilingualCaptions",
            dependencies: ["CaptionsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)] // Task 7에서 .v6으로 전환
        ),
        .testTarget(
            name: "CaptionsCoreTests",
            dependencies: ["CaptionsCore"]
        )
    ]
)
```

`dependencies:` 를 Package 레벨에 두지 않는다 — 서드파티 의존성 금지.

현재 `AppDelegate`는 Swift 6 타입 검사에서 UI 프로퍼티의 MainActor 격리 오류가 발생한다.
임시 `.v5`는 Task 1의 범위를 빌드 이주로 제한하기 위한 결정이다. `swift build -v`로 타깃별
언어 모드와 기존 `@main` 진입점 처리를 확인한다. 진입점 오류가 나면 `main.swift`를
`AppMain.swift`로 이름을 바꾸어 `@main`을 유지하고 Task 7의 분리 경로에도 반영한다.

- [ ] **Step 2: `CaptionsCore` 자리표시 파일 생성**

빈 타깃은 SwiftPM 이 경고하므로 최소 내용을 넣는다.

`Sources/CaptionsCore/CaptionsCore.swift`:
```swift
/// CaptionsCore — UI 의존이 없는 자막 로직. 테스트 대상은 전부 이 모듈에 있다.
public enum CaptionsCore {
    public static let moduleName = "CaptionsCore"
}
```

- [ ] **Step 3: `test.sh` 작성 (실행 권한 포함)**

맨 `swift test` 는 이 머신에서 `no such module 'Testing'` 으로 실패한다. 프레임워크 경로와 rpath 두 개를 넣어야 한다.

```sh
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
```

```bash
chmod +x test.sh
```

- [ ] **Step 4: 실패하는 스모크 테스트 작성**

`Tests/CaptionsCoreTests/SmokeTests.swift`:
```swift
import Testing
@testable import CaptionsCore

@Test func 모듈이_연결된다() {
    #expect(CaptionsCore.moduleName == "CaptionsCore")
}

@Test func 테스트하네스가_실패를_잡는다() {
    #expect(CaptionsCore.moduleName != "CaptionsCore", "이 테스트는 실패해야 한다")
}
```

- [ ] **Step 5: 테스트를 돌려 두 번째가 실패하는지 확인**

Run: `./test.sh`
Expected: `모듈이_연결된다` PASS, `테스트하네스가_실패를_잡는다` FAIL
(하네스가 실패를 실제로 보고하는지 확인하는 단계다. 여기서 둘 다 통과하면 하네스가 고장난 것이다.)

- [ ] **Step 6: 두 번째 테스트를 삭제**

`Tests/CaptionsCoreTests/SmokeTests.swift` 에서 `테스트하네스가_실패를_잡는다` 함수를 지운다.

- [ ] **Step 7: 테스트 통과 확인**

Run: `./test.sh`
Expected: `1 test` PASS

- [ ] **Step 8: `build.sh` 를 SPM 기반으로 교체**

```sh
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
```

- [ ] **Step 9: `Info.plist` 최소 버전 갱신**

`LSMinimumSystemVersion` 값을 `14.0` 에서 `26.0` 으로 바꾼다. 나머지 키는 그대로 둔다.
(`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` 은 유지. 화면 기록 권한은
usage description 키가 없고 TCC 가 직접 처리하므로 추가할 것이 없다.)

- [ ] **Step 10: 빌드·실행 확인**

Run: `./run.sh`
Expected: 기준 커밋과 동일하게 자막 패널이 뜨고 마이크 자막이 동작한다. 동작이 달라지면 안 된다.

- [ ] **Step 11: 프로젝트 `CLAUDE.md` 작성**

전역 지침(`~/.claude/CLAUDE.md`)이 "프로젝트 지식은 각 프로젝트의 CLAUDE.md에" 를 요구한다.

`CLAUDE.md`:
```markdown
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
```

- [ ] **Step 12: agent_manager 보드에 등록**

`~/Desktop/vivecoding/agent_manager/PROJECTS.md` 를 읽고, 기존 행 형식에 맞춰
`LiveBilingualCaptions` 행을 추가한다. **기존 형식을 따르고 새 형식을 만들지 않는다.**

- [ ] **Step 13: 커밋**

```bash
git add -A
git commit -m "build: migrate to SwiftPM with swift-testing harness

Two targets: CaptionsCore (testable, no UI) and LiveBilingualCaptions.
test.sh wraps swift test with the framework paths swift-testing needs
on a machine without full Xcode. build.sh now assembles the bundle from
swift build output and prefers a stable self-signed identity so TCC
permissions survive rebuilds.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 2: 언어 테이블과 감지 규칙

스펙 §6.4. 순수 로직이므로 완전히 TDD 한다.

**Files:**
- Create: `Sources/CaptionsCore/LanguageTable.swift`, `Tests/CaptionsCoreTests/LanguageTableTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `public struct CaptionLanguage: Sendable, Equatable, Identifiable` — `id: String`, `locale: Locale`, `displayName: String`, `uniqueRanges: [ClosedRange<UInt32>]`, `sharedRanges: [ClosedRange<UInt32>]`
  - `public struct LanguageTable: Sendable` — `languages: [CaptionLanguage]`, `static let `default`: LanguageTable`, `func detect(_ text: String, current: CaptionLanguage) -> CaptionLanguage`, `func target(for: CaptionLanguage, preferredID: String?) -> CaptionLanguage?`, `func language(id: String) -> CaptionLanguage?`
  - `public static let korean: CaptionLanguage`, `public static let english: CaptionLanguage`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CaptionsCoreTests/LanguageTableTests.swift`:
```swift
import Testing
import Foundation
@testable import CaptionsCore

private let table = LanguageTable.default
private let ko = CaptionLanguage.korean
private let en = CaptionLanguage.english

@Test func 한글이_한_글자라도_있으면_한국어() {
    #expect(table.detect("hello 안녕", current: en) == ko)
    #expect(table.detect("안", current: en) == ko)
}

@Test func 라틴만_세_글자_이상이면_영어() {
    #expect(table.detect("hello world", current: ko) == en)
}

@Test func 라틴이_세_글자_미만이면_현재_언어_유지() {
    #expect(table.detect("hi", current: ko) == ko)
    #expect(table.detect("hi", current: en) == en)
}

@Test func 어느_범위에도_안_걸리면_현재_언어_유지() {
    #expect(table.detect("123 !!", current: ko) == ko)
    #expect(table.detect("", current: en) == en)
}

@Test func 번역_대상은_감지된_언어가_아닌_언어() {
    #expect(table.target(for: ko) == en)
    #expect(table.target(for: en) == ko)
}

@Test func 언어를_id로_찾는다() {
    #expect(table.language(id: "ko-KR") == ko)
    #expect(table.language(id: "없음") == nil)
}

@Test func 언어_추가는_배열_한_줄() {
    let ja = CaptionLanguage(
        locale: Locale(identifier: "ja-JP"), displayName: "일본어",
        uniqueRanges: [0x3040...0x309F, 0x30A0...0x30FF], sharedRanges: [])
    let extended = LanguageTable(languages: [ko, en, ja])
    #expect(extended.detect("こんにちは", current: en) == ja)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `./test.sh`
Expected: FAIL — `cannot find 'LanguageTable' in scope`

- [ ] **Step 3: 구현 작성**

`Sources/CaptionsCore/LanguageTable.swift`:
```swift
import Foundation

/// 자막이 다룰 수 있는 언어 하나. 감지에 쓸 유니코드 범위를 함께 들고 있다.
public struct CaptionLanguage: Sendable, Equatable, Identifiable {
    /// 이 언어만 쓰는 문자 범위(예: 한글 음절). 한 글자만 나와도 이 언어로 확정한다.
    public let uniqueRanges: [ClosedRange<UInt32>]
    /// 여러 언어가 공유하는 문자 범위(예: 라틴 문자).
    public let sharedRanges: [ClosedRange<UInt32>]
    public let locale: Locale
    public let displayName: String

    public var id: String { locale.identifier }

    public init(locale: Locale, displayName: String,
                uniqueRanges: [ClosedRange<UInt32>], sharedRanges: [ClosedRange<UInt32>]) {
        self.locale = locale
        self.displayName = displayName
        self.uniqueRanges = uniqueRanges
        self.sharedRanges = sharedRanges
    }

    public static let korean = CaptionLanguage(
        locale: Locale(identifier: "ko-KR"), displayName: "한국어",
        uniqueRanges: [0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F],
        sharedRanges: [])

    public static let english = CaptionLanguage(
        locale: Locale(identifier: "en-US"), displayName: "영어",
        uniqueRanges: [],
        sharedRanges: [0x41...0x5A, 0x61...0x7A])

    func uniqueHits(in scalars: String.UnicodeScalarView) -> Int {
        scalars.count { s in uniqueRanges.contains { $0.contains(s.value) } }
    }

    func sharedHits(in scalars: String.UnicodeScalarView) -> Int {
        scalars.count { s in sharedRanges.contains { $0.contains(s.value) } }
    }
}

/// 앱이 아는 언어들의 목록. 감지·전환·번역 대상 선택이 전부 이 테이블만 읽는다.
public struct LanguageTable: Sendable {
    public let languages: [CaptionLanguage]

    public init(languages: [CaptionLanguage]) { self.languages = languages }

    public static let `default` = LanguageTable(languages: [.korean, .english])

    public func language(id: String) -> CaptionLanguage? {
        languages.first { $0.id == id }
    }

    /// 공유 범위(라틴 등)만으로 언어를 정할 때 요구하는 최소 글자 수.
    /// 이보다 적으면 근거가 약하다고 보고 판단을 보류한다.
    private static let sharedHitThreshold = 3

    /// 스펙 §6.4 의 감지 규칙.
    public func detect(_ text: String, current: CaptionLanguage) -> CaptionLanguage {
        let scalars = text.unicodeScalars

        // 1) 고유 범위가 잡히면 그 언어로 확정. 둘 이상이면 글자 수가 많은 쪽.
        let uniqueMatches = languages
            .map { ($0, $0.uniqueHits(in: scalars)) }
            .filter { $0.1 > 0 }
        if let best = uniqueMatches.max(by: { $0.1 < $1.1 }) {
            return best.0
        }

        // 2) 공유 범위만 있으면 테이블 순서상 첫 번째. 단 최소 글자 수를 넘겨야 한다.
        for language in languages where language.sharedHits(in: scalars) >= Self.sharedHitThreshold {
            return language
        }

        // 3) 근거가 없으면 현재 언어 유지.
        return current
    }

    /// 3개 이상일 때 설정한 대상을 우선한다. 자기 자신/없는 ID는 첫 다른 언어로 복구한다.
    public func target(for source: CaptionLanguage, preferredID: String? = nil) -> CaptionLanguage? {
        if languages.count >= 3, let preferredID,
           let preferred = language(id: preferredID), preferred != source {
            return preferred
        }
        return languages.first { $0 != source }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `./test.sh`
Expected: 기존 7개와 아래 대상 선택 테스트 전부 PASS.

추가 테스트: `[ko, en, ja]`에서 기본 대상 `ja` 선택, 원문과 대상이 모두 `ja`일 때
첫 다른 언어 선택, 없는 대상 ID 복구, 2개 언어에서 반대 언어 유지.

- [ ] **Step 5: 커밋**

```bash
git add Sources/CaptionsCore/LanguageTable.swift Tests/CaptionsCoreTests/LanguageTableTests.swift
git commit -m "feat: add language table with explicit detection rules

Replaces the hardcoded 0xAC00...0xD7A3 hangul checks that were scattered
across the base commit. Unique ranges win on a single character; shared
ranges (latin) need 3+ characters; otherwise the current language holds.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 3: 자막 문자열 가공 · 설정 영속

순수 로직 2종을 한 태스크로 묶는다. 둘 다 작고, 둘 다 이후 태스크가 즉시 쓴다.

**Debouncer는 만들지 않는다.** 원안에 있었으나 Task 6이 번역 디바운스를 submit이 소유한
Task 안에서 처리하기로 확정되면서 쓰는 곳이 없어졌다. 아무도 안 쓰는 actor를 만들고
테스트까지 붙이는 것은 죽은 코드다. 나중에 디바운스가 여러 곳에서 필요해지면 그때 뽑는다.

**Files:**
- Create: `Sources/CaptionsCore/CaptionText.swift`, `Sources/CaptionsCore/Settings.swift`, `Tests/CaptionsCoreTests/CaptionTextTests.swift`, `Tests/CaptionsCoreTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `CaptionLanguage` (Task 2)
- Produces:
  - `public enum CaptionText { public static func tail(_ text: String, limit: Int = 92) -> String }`
  - `public enum AudioSourceKind: String, Codable, Sendable, CaseIterable { case microphone, systemAudio }`
  - `public enum LanguageMode: Equatable, Codable, Sendable { case auto, fixed(String) }`
  - `public enum DetectorSensitivity: String, Codable, Sendable, CaseIterable { case low, medium, high }`
  - `public struct Settings: Codable, Equatable, Sendable` — `languageMode`, `preferredTargetID`, `audioSource`, `fontSize`, `captionHoldSeconds`, `detectorSensitivity`, `refinementEnabled`, `panelOriginX`, `panelOriginY`, `panelWidth`, `panelHeight`; `static let `default``, `static func load(from: UserDefaults) -> Settings`, `func save(to: UserDefaults)`

- [ ] **Step 1: 실패하는 테스트 작성 — 자막 꼬리 자르기**

기준 커밋 435–443줄의 `captionTail` 을 옮기되 경계 동작을 명시한다.

`Tests/CaptionsCoreTests/CaptionTextTests.swift`:
```swift
import Testing
@testable import CaptionsCore

@Test func 제한보다_짧으면_그대로() {
    #expect(CaptionText.tail("짧은 문장", limit: 92) == "짧은 문장")
}

@Test func 제한과_같으면_그대로() {
    let text = String(repeating: "가", count: 10)
    #expect(CaptionText.tail(text, limit: 10) == text)
}

@Test func 제한을_넘으면_공백_경계에서_자르고_말줄임표() {
    let result = CaptionText.tail("aaaa bbbb cccc", limit: 9)
    #expect(result.hasPrefix("…"))
    #expect(result == "…cccc")
}

@Test func 공백이_없는_장문은_그냥_뒤에서_자른다() {
    let result = CaptionText.tail(String(repeating: "가", count: 20), limit: 5)
    #expect(result == "…" + String(repeating: "가", count: 5))
}

@Test func 빈_문자열은_빈_문자열() {
    #expect(CaptionText.tail("", limit: 92) == "")
}
```

- [ ] **Step 2: 실패하는 테스트 작성 — 설정 라운드트립**

`Tests/CaptionsCoreTests/SettingsTests.swift`:
```swift
import Testing
import Foundation
@testable import CaptionsCore

private func freshDefaults(_ name: String) -> UserDefaults {
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Test func 저장하고_불러오면_같은_값() {
    let defaults = freshDefaults("test.roundtrip")
    var settings = Settings.default
    settings.languageMode = .fixed("en-US")
    settings.audioSource = .systemAudio
    settings.fontSize = 28
    settings.captionHoldSeconds = 4.5
    settings.detectorSensitivity = .high
    settings.refinementEnabled = true
    settings.panelOriginX = 120
    settings.panelOriginY = 64
    settings.preferredTargetID = "en-US"
    settings.panelWidth = 720
    settings.panelHeight = 240

    settings.save(to: defaults)
    #expect(Settings.load(from: defaults) == settings)
}

@Test func 저장된_값이_없으면_기본값() {
    let defaults = freshDefaults("test.empty")
    #expect(Settings.load(from: defaults) == Settings.default)
}

@Test func 손상된_값이_있으면_기본값으로_복구() {
    let defaults = freshDefaults("test.corrupt")
    defaults.set("이건 JSON 이 아니다", forKey: Settings.storageKey)
    #expect(Settings.load(from: defaults) == Settings.default)
}

@Test func 기본값은_LLM_보정이_꺼져_있다() {
    #expect(Settings.default.refinementEnabled == false)
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `./test.sh`
Expected: FAIL — `cannot find 'CaptionText' / 'Settings' in scope`

- [ ] **Step 4: `CaptionText` 구현**

`Sources/CaptionsCore/CaptionText.swift`:
```swift
import Foundation

public enum CaptionText {
    /// 자막 줄이 넘칠 때 앞을 버리고 뒤를 남긴다. 말은 계속 흐르므로 최신 쪽이 중요하다.
    /// 가능하면 단어 경계에서 자르고, 경계가 없으면 글자 수로 자른다.
    public static func tail(_ text: String, limit: Int = 92) -> String {
        guard text.count > limit else { return text }
        let suffix = String(text.suffix(limit))
        if let space = suffix.firstIndex(of: " ") {
            return "…" + suffix[suffix.index(after: space)...]
        }
        return "…" + suffix
    }
}
```

- [ ] **Step 5: `Settings` 구현**

`Sources/CaptionsCore/Settings.swift`:
```swift
import Foundation

public enum AudioSourceKind: String, Codable, Sendable, CaseIterable {
    case microphone, systemAudio

    public var displayName: String {
        switch self {
        case .microphone: "마이크"
        case .systemAudio: "시스템 오디오"
        }
    }
}

public enum LanguageMode: Equatable, Codable, Sendable {
    case auto
    case fixed(String)      // CaptionLanguage.id
}

public enum DetectorSensitivity: String, Codable, Sendable, CaseIterable {
    case low, medium, high

    public var displayName: String {
        switch self {
        case .low: "낮음"
        case .medium: "보통"
        case .high: "높음"
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var languageMode: LanguageMode
    public var preferredTargetID: String?
    public var audioSource: AudioSourceKind
    public var fontSize: Double
    public var captionHoldSeconds: Double
    public var detectorSensitivity: DetectorSensitivity
    public var refinementEnabled: Bool
    public var panelOriginX: Double?
    public var panelOriginY: Double?
    public var panelWidth: Double?
    public var panelHeight: Double?

    public static let storageKey = "settings.v1"

    public static let `default` = Settings(
        languageMode: .fixed("ko-KR"),
        preferredTargetID: nil,
        audioSource: .microphone,
        fontSize: 20,
        captionHoldSeconds: 10,
        detectorSensitivity: .medium,
        refinementEnabled: false,      // 네트워크·비용이 드는 기능은 기본 꺼짐
        panelOriginX: nil,
        panelOriginY: nil,
        panelWidth: nil,
        panelHeight: nil)

    /// 저장된 값이 없거나 형식이 깨졌으면 기본값으로 돌아간다.
    /// 설정 하나 때문에 앱이 못 뜨는 상황을 만들지 않는다.
    public static func load(from defaults: UserDefaults) -> Settings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .default }
        return decoded
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
```

`손상된_값이_있으면_기본값으로_복구` 테스트는 문자열을 넣는데 `data(forKey:)` 는 `nil` 을
돌려주므로 기본값으로 떨어진다. 의도한 동작이다.

- [ ] **Step 6: 테스트 통과 확인**

Run: `./test.sh`
Expected: 기존 테스트 및 추가 회귀 테스트 전부 PASS. 총수는 실제 테스트 출력으로 기록한다.
Settings 라운드트립에 `preferredTargetID`, `panelWidth`, `panelHeight`를 추가하고,
새 optional 필드가 없는 기존 JSON도 기존 설정값을 보존하며 읽히는지 검증한다.

- [ ] **Step 7: 커밋**

```bash
git add Sources/CaptionsCore Tests/CaptionsCoreTests
git commit -m "feat: add caption text and settings persistence

Settings fall back to defaults on corrupt data so one bad value cannot
stop the app from launching, and unknown-but-absent optional fields
decode without wiping the values that are there.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 4: 오디오 소스 프로토콜과 마이크 구현

스펙 §6.1. 오디오 캡처는 유닛테스트 대상이 아니므로 **수동 스모크로 검증**한다.

**Files:**
- Create: `Sources/CaptionsCore/AudioSource.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `@MainActor public protocol AudioSource: AnyObject` — `func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat`, `func stop() async`
  - `public final class MicSource: AudioSource`
  - `public enum AudioSourceError: LocalizedError` — `case noInput, permissionDenied, noDisplay`

- [ ] **Step 1: 프로토콜과 마이크 구현 작성**

`start`는 캡처의 실제 포맷을 반환한다. 이것은 분석기가 지원하는 포맷과 다를 수 있다.
Task 5에서 지원 포맷을 조회하고 변환한다. 시스템 오디오는 설정 포맷을 알 수 있으나
실제 첫 버퍼의 포맷을 확인한다. 따라서 첫 버퍼 선도착·무음·취소도 시작 계약에 포함한다.

`Sources/CaptionsCore/AudioSource.swift`:
```swift
import AVFoundation

public enum AudioSourceError: LocalizedError {
    case noInput
    case permissionDenied
    case noDisplay

    public var errorDescription: String? {
        switch self {
        case .noInput: "마이크 입력을 찾지 못했습니다"
        case .permissionDenied: "권한이 거부되었습니다"
        case .noDisplay: "캡처할 디스플레이를 찾지 못했습니다"
        }
    }
}

/// 오디오 한 줄기. 구현은 마이크와 시스템 오디오 두 가지다.
@MainActor
public protocol AudioSource: AnyObject {
    /// 캡처를 시작하고 실제 오디오 포맷을 돌려준다.
    /// sink는 콜백이 반환되기 전에 버퍼를 복사/변환한다. 빌린 버퍼를 비동기로 보관하지 않는다.
    func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat
    func stop() async
}

/// AVAudioEngine 마이크 입력. 마이크 권한만 필요하고 화면 기록 권한은 필요 없다.
@MainActor
public final class MicSource: AudioSource {
    private let engine = AVAudioEngine()
    private var started = false

    public init() {}

    public func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw AudioSourceError.noInput }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink(buffer)
        }
        engine.prepare()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        started = true
        return format
    }

    public func stop() async {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        started = false
    }
}
```

- [ ] **Step 2: 컴파일 확인**

Run: `swift build --package-path . `
Expected: 성공. 경고 없음.

- [ ] **Step 3: 커밋**

```bash
git add Sources/CaptionsCore/AudioSource.swift
git commit -m "feat: add AudioSource protocol with microphone implementation

start() reports the capture format; the analyzer's compatible format
is negotiated separately. stop() waits for capture teardown.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 5: 인식 파이프라인 교체 — 여기가 실제 개선

스펙 §6.2. 기준 커밋의 인식 코드 전부를 `SpeechAnalyzer` 로 갈아치운다.

**이 태스크는 두 단계로 나눠 실행한다.** 검토 수정으로 참조 코드가 구현 계약으로 바뀌면서
범위가 커졌고, 한 번에 맡기면 검증 없이 통과할 위험이 있다. 이음매는 명확하다 —
`AudioBufferConverter`는 Speech 프레임워크에 의존하지 않고 합성 PCM으로 완전히 테스트된다.

- **5A**: `Transcript` + `AudioBufferConverter`. 순수 로직, 완전 TDD. Speech 불필요.
- **5B**: `SpeechPipeline` + `PipelineController` + `main.swift` 재배선. 5A가 통과한 뒤에만 시작한다.

5A가 끝나면 앱은 여전히 기준 커밋처럼 동작한다(아직 배선 전). 5B가 끝나야 엔진이 바뀐다.

`bestAvailableAudioFormat`에는 `considering naturalFormat:` 오버로드가 있다
(SDK 확인 완료). 캡처 포맷을 넘기면 협상 결과가 입력에 가까워져 변환 폭이 줄어든다.
`bestAvailableAudioFormat(compatibleWith: modules, considering: captureFormat)`을 먼저 시도하고,
nil이면 `considering:` 없는 오버로드로 한 번 더 시도한 뒤 그래도 nil이면 시작 실패를 보고한다.

**Files:**
- Create: `Sources/CaptionsCore/Transcript.swift`, `Sources/CaptionsCore/SpeechPipeline.swift`, `Sources/CaptionsCore/AudioBufferConverter.swift`, `Sources/CaptionsCore/PipelineController.swift`, `Tests/CaptionsCoreTests/TranscriptTests.swift`, `Tests/CaptionsCoreTests/PipelineControllerTests.swift`, `Tests/CaptionsCoreTests/AudioBufferConverterTests.swift`
- Modify: `Sources/LiveBilingualCaptions/main.swift` — `SFSpeechRecognizer` 경로 전부 제거 후 `SpeechPipeline` 배선

**Interfaces:**
- Consumes: `AudioSource`, `MicSource` (Task 4), `CaptionLanguage`, `LanguageTable` (Task 2), `DetectorSensitivity` (Task 3)
- Produces:
  - `public enum Transcript: Sendable, Equatable` — `case partial(String)`, `case final(String)`; `var text: String`, `var isFinal: Bool`
  - `PipelineEvent` — 설치/청취/전사/오류. 모든 이벤트에 실행 ID, 전사에는 발화 ID·수정 번호·생성 당시 언어 포함
  - `@MainActor SpeechPipeline` — Run별 자원 소유, 포맷 변환, 시작/전환/종료. AppDelegate가 직접 호출하지 않음
  - `@MainActor PipelineController` — `requestStart(configuration:)`, `requestStop()`, `requestReconfigure(configuration:)`, 실행 상태·현행 이벤트 콜백. Step 5의 직렬화 계약 필수

- [ ] **Step 1: `Transcript` 테스트 작성**

`Tests/CaptionsCoreTests/TranscriptTests.swift`:
```swift
import Testing
@testable import CaptionsCore

@Test func 부분과_확정을_구분한다() {
    #expect(Transcript.partial("안녕").isFinal == false)
    #expect(Transcript.final("안녕하세요").isFinal == true)
}

@Test func 텍스트를_꺼낸다() {
    #expect(Transcript.partial("안녕").text == "안녕")
    #expect(Transcript.final("안녕하세요").text == "안녕하세요")
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `./test.sh`
Expected: FAIL — `cannot find 'Transcript' in scope`

- [ ] **Step 3: `Transcript` 구현**

`Sources/CaptionsCore/Transcript.swift`:
```swift
import Foundation

/// 인식 결과 한 조각. 부분 결과는 계속 덮어써지고, 확정 결과는 더 바뀌지 않는다.
/// 이 구분이 번역 2단(LLM 보정)의 트리거가 된다 — 부분에 붙이면 자막이 깜빡인다.
public enum Transcript: Sendable, Equatable {
    case partial(String)
    case final(String)

    public var text: String {
        switch self {
        case .partial(let t), .final(let t): t
        }
    }

    public var isFinal: Bool {
        if case .final = self { return true }
        return false
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `./test.sh`
Expected: Transcript 2개 및 이전 태스크의 기존·추가 테스트 전부 PASS.

- [ ] **Step 5: `SpeechPipeline` 구현**

이전 코드 예시의 원본 버퍼 직접 전달과 await 후 공유 상태 정리는 제거했다.
아래는 구현 계약이며 완성 코드가 아니다. 이 순서와 회귀 테스트를 충족하는 구현을
`SpeechPipeline.swift`, `AudioBufferConverter.swift`, `PipelineController.swift`에 작성한다.

**A. 포맷 변환**

1. 모델 설치 후 `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`으로
   `[detector, transcriber]`의 공통 포맷을 조회한다. nil이면 시작 실패를 보고한다.
2. `prepareToAnalyze(in:)`에 이 포맷을 전달한다. 마이크 native format이나
   시스템 오디오의 48kHz stereo 포맷을 그대로 전달하지 않는다.
3. sink 안에서 입력 포맷을 확인하고 `AVAudioConverter(from:to:)`를 구성한다.
   변환기는 하나의 직렬 실행 영역에서 사용하며 버퍼마다 새로 만들지 않는다.
   콜백 종료 후에도 쓸 데이터는 소유한 버퍼에 복사한다.
4. 출력 용량은 `ceil(inputFrames * outputRate / inputRate)`를 기준으로 확보하고,
   converter가 입력을 소비하고 출력을 배출할 때까지 처리한다. input block에서 같은 입력을
   두 번 공급하지 않는다. 출력은 매번 독립된 버퍼에 보관한다.
5. 변환된 버퍼만 `AnalyzerInput`으로 전달한다. 입력 큐는 최대 약 2초 분량으로 제한하고,
   초과하면 PCM을 조용히 버리지 말고 오류를 보고한 뒤 실행을 정지한다. 입력 포맷 변경도
   감지하고 재구성한다. 장치 변경을 무시하지 않는다.

근거: [Apple — bestAvailableAudioFormat](https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat%28compatiblewith%3A%29).
분석기는 자동 리샘플링하지 않는다. 변환기의 입력 공급과 출력 프레임 수는 합성 PCM으로 검증한다.

**B. 실행 소유권과 취소**

- `@MainActor PipelineController`를 유일한 진입점으로 둔다. `requestStart(configuration:)`,
  `requestStop()`, `requestReconfigure(configuration:)`은 동기적으로 요청을 받아 generation을
  즉시 갱신하고 실행 중 작업을 취소한다. worker 하나가 이전 실행을 정리한 뒤 최신 요청을
  시작한다. 버튼마다 별도의 `Task { stop; start }`를 만들지 않는다.
- `Run`이 source, analyzer, 입력 continuation, analysis/results/progress 태스크를 소유한다.
  await 후 공유 프로퍼티를 nil로 만들어 새 실행을 지우지 않는다. 정리는 여러 번 호출해도 안전해야 한다.
- locale 확인·모델 다운로드·예약·source.start·prepare·setModules의 각 await 뒤에
  `Task.checkCancellation()`과 generation 일치를 검사한다. 다운로드가 취소를 무시하고
  완료돼도 캡처는 시작하지 않는다.
- 진행률 태스크는 `defer { reporter.cancel() }`로 성공·실패·취소 모두 정리한다.
  설치·결과·오류 이벤트에도 generation을 넣어 현행 Run의 이벤트만 알린다.
- 정리 순서는 sink 수신 차단 → source.stop 완료 → continuation 종료 → 결과/분석 태스크 취소 →
  analyzer 종료다. 시작 중 실패에도 같은 정리를 적용한다.
- source.start가 대기 중이면 소스의 취소 핸들러가 그 대기를 해제한다.
  worker가 시작 완료만 기다리느라 정지하지 못하는 교착 상태를 만들지 않는다.
- sensitivity는 실행 configuration에서 읽는다. 변경하면 재구성한다. 언어 전환은 포맷이
  호환될 때 `setModules`로 처리하고, 아니면 변환기를 안전하게 재구성하거나 안내 후 재시작한다.

**C. 전사 이벤트 식별**

`Transcript`의 partial/final은 유지하되 이벤트에 `runID`, `utteranceID`, `revision`,
`sourceLanguage`를 붙인다. `SpeechTranscriber.Result`의 오디오 시간 범위를 이용해
동일 구간의 volatile 갱신과 final을 같은 ID로 묶는다. 문자열 일치로 중복을 판정하지 않는다.
확정 구간과 후속 volatile 구간이 교차 도착하는 경우를 테스트하여 과거 구간의 final로
최신 원문이 되돌아가지 않게 한다. 번역 언어는 이벤트 생성 시점의 값으로 고정한다.

- [ ] **Step 5a: 회귀 테스트**

실제 장치 없이 가짜 소스와 수동 재개 continuation으로 검증한다. 48kHz stereo / 44.1kHz mono
합성 입력에서 선택한 분석 포맷의 rate·channels·프레임 수·연속성을 확인한다.
시작 중 정지, 시작 실패, 연속 전환, 이전 결과/오류 도착, 다운로드 실패 시 진행률 태스크 종료,
같은 문장을 다른 구간에서 두 번 말하는 경우를 추가한다.

- [ ] **Step 6: `main.swift` 에서 기존 인식 코드 제거하고 파이프라인 배선**

`Sources/LiveBilingualCaptions/main.swift` 에서 **삭제**할 것:
- `import Speech` 의 `SFSpeechRecognizer` 사용 전부
- 프로퍼티 `legacyRecognizer`, `legacyRequest`, `legacyTask`, `latestRecognizedText`,
  `latestRecognitionConfidence`, `lastVoiceAt`, `speechActive`, `silenceTimer`, `analyzer`,
  `transcriber`, `inputContinuation`, `analysisTask`, `resultsTask`, `audioEngine`
- 메서드 `startLegacyTranscription()`, `beginLegacyRecognitionTask()`, `voiceDetected()`,
  `checkForSilence()`, `adaptLanguageForNextUtterance()`, `startModernTranscription()`

**추가**할 것 — `import CaptionsCore` 와 아래 배선:

```swift
// AppDelegate는 @MainActor. controller와 currentConfiguration은 Step 5에서 연결한다.
private func startListening() {
    controller.requestStart(configuration: currentConfiguration)
}

private func stopListening() {
    invalidateCaptions() // Task 6부터 translator.reset()도 동기적으로 호출
    controller.requestStop()
}
```

`currentConfiguration`은 설정에서 만든 소스·언어·민감도의 스냅샷이다. 자동 모드의 최초
언어는 한국어, 고정 모드는 저장한 ID를 쓴다. `invalidateCaptions()`는 기존 번역 작업과
clear 타이머를 취소하고 이후 Task 6에서 번역 세대도 무효화한다.
`running`과 버튼 상태는 controller의 starting/listening/stopping/stopped/failed 상태에서
한 번에 갱신한다. 시작 요청만 보냈다고 listening 상태로 바꾸지 않는다.
전사 수신 시 원문 갱신, 이전 번역 무효화, 번역 요청, 유지 타이머 재예약을 함께 처리한다.

자동 모드는 UI에 `자동 (실험)`으로 표시하고 기본값은 고정 한국어로 둔다. 문자열 분류는
현재 locale의 오인식에 종속되므로 자동 전환 성공을 보장하지 않는다. 실험 모드에서만
final 문자열로 전환을 제안하며, 전환 실행은 반드시 controller를 거친다.
수동 한국어/영어 전환과 설정의 fixed ID를 같은 configuration 경로로 연결한다.

`scheduleTranslation(of:)` 는 아직 기존 `String` 기반 구현을 쓴다. 시그니처만
`Transcript` 를 받도록 바꾸고 내부에서 `transcript.text` 를 넘긴다. Task 6 에서 교체한다.

- [ ] **Step 7: 빌드 확인**

Run: `./build.sh`
Expected: 성공. `SFSpeechRecognizer` 참조가 하나도 남지 않아야 한다.
확인: `grep -c "SFSpeech\|legacy" Sources/LiveBilingualCaptions/main.swift` → `0`

- [ ] **Step 8: 수동 스모크**

Run: `./run.sh`
확인 항목:
1. 최초 실행 시 "음성 모델 설치 중 · N%" 가 뜨거나, 이미 설치됐으면 바로 "● 듣는 중".
2. 한국어로 말하면 자막이 **문장 도중에 초기화되지 않고** 이어서 자란다.
   (기준 커밋은 `voiceDetected()` 가 라벨을 비워서 자막이 끊겼다.)
3. 한국어/영어 고정 모드에서 각각 인식되고 수동 전환이 적용되는지.
4. 자동 모드가 실험 기능으로 표시되는지. 자동 전환 성공률은 별도로 기록하고 수동 전환 결과와 혼동하지 않는다.
5. 다운로드/시작 중 정지하면 나중에 캡처가 켜지지 않는지. 빠른 시작·정지·소스 전환 후 마지막 요청만 남는지.

- [ ] **Step 9: 커밋**

```bash
git add -A
git commit -m "feat: replace SFSpeechRecognizer with SpeechAnalyzer pipeline

Deletes the hand-rolled RMS voice detection, the silence timer that
restarted recognition every utterance, and the confidence-threshold
language heuristic. SpeechDetector handles VAD and setModules swaps the
language when the audio formats remain compatible. Manual language
selection is the supported path; text-based auto switching is experimental.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 6: 온디바이스 번역으로 교체

스펙 §6.3 의 1단. Google `gtx` 엔드포인트를 제거한다.

**Files:**
- Create: `Sources/CaptionsCore/Translator.swift`, `Tests/CaptionsCoreTests/TranslatorTests.swift`
- Modify: `Sources/LiveBilingualCaptions/main.swift` — Google 번역 경로 제거, `Translator` 배선
  (Task 5가 이 파일을 이미 재작성했으므로 기준 커밋 줄번호로 찾지 말고 심볼명으로 찾는다)

**Interfaces:**
- Consumes: `CaptionLanguage`, `LanguageTable` (Task 2), `Transcript`와 발화 ID (Task 5)
- Produces:
  - `public protocol TranslationRefiner: Sendable { func refine(_ draft: String, source: String, context: [String]) async throws -> String }`
  - `public enum PackStatus: Sendable, Equatable { case installed, needsDownload, unsupported }`
  - `public typealias TranslateFunction = @Sendable (String, CaptionLanguage, CaptionLanguage) async -> String?`
  - `@MainActor public final class Translator` — `init(table:translate:)`, `onDevice`, `refiner`, `preferredTargetID`, `onTranslation`, `packStatus(from:to:)`, `submit(_:from:captionID:) -> Task<Void, Never>?`, `handle(_:from:captionID:) async` (테스트 편의), `reset()`

번역 디바운스는 submit이 소유한 Task에서 처리한다. 별도 Debouncer actor에 비동기로 취소를
보내면 reset 직후 새 작업까지 취소하는 경합이 생길 수 있다. 그래서 Task 3에서 Debouncer를
아예 만들지 않는다 — 여기서 쓰지 않으면 쓰는 곳이 없다.

- [ ] **Step 1: 실패하는 테스트 작성**

실제 `TranslationSession` 은 시스템 언어팩 설치 상태에 의존하므로 테스트에 넣지 않는다.
대신 번역 함수를 **주입 가능**하게 만들어 가짜를 넣는다. 그래야 테스트가 이 머신의
언어팩 유무와 무관하게 항상 같은 결과를 낸다.

`Tests/CaptionsCoreTests/TranslatorTests.swift`:
```swift
import Testing
import Foundation
@testable import CaptionsCore

private actor SpyRefiner: TranslationRefiner {
    private var calls: [String] = []
    func refine(_ draft: String, source: String, context: [String]) async throws -> String {
        calls.append(source)
        return draft + " (보정됨)"
    }
    func recorded() -> [String] { calls }
}

/// 언어팩과 무관하게 항상 같은 값을 주는 가짜 번역기.
private let fakeTranslate: TranslateFunction = { text, _, _ in "[번역] " + text }

@Test @MainActor func 보정기는_확정_전사에만_호출된다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy

    await translator.handle(.partial("안녕"), from: .korean)
    await translator.handle(.partial("안녕하세"), from: .korean)
    #expect(await spy.recorded().isEmpty, "부분 전사에는 보정기가 붙으면 안 된다")

    await translator.handle(.final("안녕하세요"), from: .korean)
    #expect(await spy.recorded() == ["안녕하세요"])
}

@Test @MainActor func 보정기가_없으면_번역문이_그대로_나온다() async {
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = nil
    var received: [(String, Bool)] = []
    translator.onTranslation = { text, refined in received.append((text, refined)) }

    await translator.handle(.final("안녕하세요"), from: .korean)
    #expect(received.count == 1)
    #expect(received[0].0 == "[번역] 안녕하세요")
    #expect(received[0].1 == false)
}

@Test @MainActor func 보정되면_두_번째_방출이_refined_true() async {
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = SpyRefiner()
    var received: [(String, Bool)] = []
    translator.onTranslation = { text, refined in received.append((text, refined)) }

    await translator.handle(.final("안녕하세요"), from: .korean)
    #expect(received.count == 2)
    #expect(received[0] == ("[번역] 안녕하세요", false))
    #expect(received[1] == ("[번역] 안녕하세요 (보정됨)", true))
}

@Test @MainActor func 같은_발화의_중복_final은_한_번만_보정한다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy
    let captionID = UUID()
    await translator.handle(.final("같은 문장"), from: .korean, captionID: captionID)
    await translator.handle(.final("같은 문장"), from: .korean, captionID: captionID)
    #expect(await spy.recorded().count == 1)
}

@Test @MainActor func reset하면_같은_문장을_다시_보정한다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy
    let captionID = UUID()
    await translator.handle(.final("문장"), from: .korean, captionID: captionID)
    translator.reset()
    await translator.handle(.final("문장"), from: .korean, captionID: captionID)
    #expect(await spy.recorded().count == 2)
}

@Test @MainActor func 같은_문장도_다른_발화면_각각_보정한다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy
    await translator.handle(.final("네"), from: .korean, captionID: UUID())
    await translator.handle(.final("네"), from: .korean, captionID: UUID())
    #expect(await spy.recorded().count == 2)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `./test.sh`
Expected: FAIL — `cannot find 'Translator' in scope`

- [ ] **Step 3: `Translator` 구현**

`Sources/CaptionsCore/Translator.swift`:
```swift
import Foundation
import Translation

/// 확정된 번역문을 문맥을 보고 다듬는 선택적 2단계.
public protocol TranslationRefiner: Sendable {
    func refine(_ draft: String, source: String, context: [String]) async throws -> String
}

public enum PackStatus: Sendable, Equatable {
    case installed
    case needsDownload
    case unsupported
}

/// 문장 하나를 번역해 돌려준다. 실패하면 nil.
/// 주입 가능하게 둔 이유는 테스트가 시스템 언어팩 설치 상태에 휘둘리지 않게 하기 위해서다.
public typealias TranslateFunction = @Sendable (String, CaptionLanguage, CaptionLanguage) async -> String?

/// 2단 번역. 1단은 온디바이스로 즉시, 2단은 확정 전사에만 LLM 보정.
@MainActor
public final class Translator {
    private let table: LanguageTable
    private let translate: TranslateFunction
    private var pending: Task<Void, Never>?
    private var generation: UInt64 = 0
    private struct SubmissionKey: Equatable {
        let captionID: UUID
        let text: String
        let sourceID: String
        let targetID: String
        let isFinal: Bool
    }
    private var lastSubmission: SubmissionKey?
    private var refinedIDs: [UUID] = []
    private var recentFinals: [String] = []

    public var preferredTargetID: String?
    public var refiner: TranslationRefiner? {
        didSet { reset() } // 끄기·키 교체 시 이미 진행 중인 보정 응답도 무효화
    }
    /// (번역문, 보정됨) — 보정됨이 true 면 크로스페이드로 교체하라는 뜻.
    public var onTranslation: (@MainActor (String, Bool) -> Void)?

    public init(table: LanguageTable, translate: @escaping TranslateFunction = Translator.onDevice) {
        self.table = table
        self.translate = translate
    }

    /// 실제 온디바이스 번역. 언어팩이 없으면 nil 을 돌려주고,
    /// 다운로드 프롬프트는 UI 의 .translationTask 가 맡는다.
    public static let onDevice: TranslateFunction = { text, source, target in
        guard await packStatus(from: source, to: target) == .installed else { return nil }
        let session = TranslationSession(
            installedSource: source.locale.language, target: target.locale.language)
        return try? await session.translate(text).targetText
    }

    public static func packStatus(from source: CaptionLanguage,
                                  to target: CaptionLanguage) async -> PackStatus {
        let status = await LanguageAvailability().status(
            from: source.locale.language, to: target.locale.language)
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    public func reset() {
        generation &+= 1
        pending?.cancel()
        pending = nil
        lastSubmission = nil
        refinedIDs.removeAll()
        recentFinals.removeAll()
    }

    /// UI 이벤트에서 직접 호출한다. Task로 감싸기 전에 이전 요청을 무효화해야 한다.
    /// captionID는 파이프라인이 발급한 발화 ID. 같은 발화의 partial/final에 동일 ID를 쓴다.
    @discardableResult
    public func submit(_ transcript: Transcript, from source: CaptionLanguage,
                       captionID: UUID) -> Task<Void, Never>? {
        guard let target = table.target(for: source, preferredID: preferredTargetID),
              !transcript.text.isEmpty else {
            reset()
            return nil
        }
        let key = SubmissionKey(captionID: captionID, text: transcript.text,
                                sourceID: source.id, targetID: target.id, isFinal: transcript.isFinal)
        if key == lastSubmission { return pending } // 중복 final로 진행 중 보정까지 취소하지 않는다
        lastSubmission = key
        generation &+= 1
        let ticket = generation
        pending?.cancel()
        pending = nil
        let text = transcript.text
        let task = Task { [weak self] in
            guard let self else { return }
            if !transcript.isFinal {
                do { try await Task.sleep(for: .milliseconds(220)) }
                catch { return }
            }
            guard self.isCurrent(ticket) else { return }
            await self.emit(text, from: source, to: target, isFinal: transcript.isFinal,
                            captionID: captionID, ticket: ticket)
        }
        pending = task
        return task
    }

    /// 테스트·직렬 호출용. 앱 이벤트 경로는 동기 submit을 쓴다.
    public func handle(_ transcript: Transcript, from source: CaptionLanguage,
                       captionID: UUID = UUID()) async {
        let task = submit(transcript, from: source, captionID: captionID)
        await task?.value
    }

    private func isCurrent(_ ticket: UInt64) -> Bool {
        ticket == generation && !Task.isCancelled
    }

    private func emit(_ text: String, from source: CaptionLanguage,
                      to target: CaptionLanguage, isFinal: Bool,
                      captionID: UUID, ticket: UInt64) async {
        guard let draft = await translate(text, source, target),
              isCurrent(ticket) else { return }
        onTranslation?(draft, false)
        guard isCurrent(ticket), isFinal, !refinedIDs.contains(captionID) else { return }
        let context = recentFinals // 현재 문장을 '직전 문장들'에 중복해서 넣지 않는다
        recentFinals.append(text)
        if recentFinals.count > 3 { recentFinals.removeFirst() }
        guard let refiner else { return }
        refinedIDs.append(captionID)
        if refinedIDs.count > 256 { refinedIDs.removeFirst() }
        guard let improved = try? await refiner.refine(
            draft, source: text, context: context),
              isCurrent(ticket), !improved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              improved != draft
        else { return }
        onTranslation?(improved, true)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `./test.sh`
Expected: 기존 테스트와 Step 5a의 응답 순서 회귀 테스트 전부 PASS. 실제 총수는 실행 결과로 기록한다.

- [ ] **Step 5: `main.swift` 에서 Google 번역 제거**

다음 심볼을 전부 삭제하고 `Translator` 로 대체한다: `translate(_:)`, `scheduleTranslation`,
`translateWork`, `pendingTranslationText`, `lastTranslationStartedAt`, `lastTranslatedSource`.
Task 5가 이 파일을 이미 재작성했으므로 **기준 커밋의 줄번호로 찾지 않는다.** 심볼명으로 찾는다.
삭제 후 `grep -n 'translateWork\|pendingTranslationText\|lastTranslationStartedAt' Sources/` 가
비어 있어야 한다.

```swift
private let translator = Translator(table: .default)

// buildWindow() 끝에 배선:
translator.onTranslation = { [weak self] text, refined in
    guard let self else { return }
    if refined {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.translatedLabel.animator().alphaValue = 0
        } completionHandler: {
            self.translatedLabel.stringValue = text
            self.translatedLabel.animator().alphaValue = 1
        }
    } else {
        self.translatedLabel.stringValue = text
    }
}

// 현재 전사 이벤트를 받아 원문을 갱신하는 동일 MainActor 호출 안에서:
// transcript / sourceLanguage / utteranceID는 이벤트에 실린 값이다.
translator.submit(transcript, from: sourceLanguage, captionID: utteranceID)
```

`submit`은 Task로 감싸지 않는다. 원문을 갱신할 때 이전 번역 표시도 비우고 새 요청을 등록한다.
지우기·정지·실행 변경·언어쌍 변경·유지 시간 만료 시 `translator.reset()`을 동기적으로 호출한다.
AppKit 애니메이션 완료 콜백에도 현재 표시 revision 검사를 넣어 이전 문장을 뒤늦게 대입하지 않는다.
Task 7의 SwiftUI 이주 전에도 이 검사는 필요하다.

- [ ] **Step 5a: 응답 순서 회귀 테스트**

continuation을 가진 가짜 번역기/보정기를 넣어 응답을 원하는 순서로 해제한다.
다음 케이스에서 과거 응답이 방출되지 않는지 검사한다. 가짜는 의도적으로 취소를 무시한다.

1. A partial 요청 → B final 요청 → B 응답 → A 응답.
2. A final 초안 표시 → B 원문 갱신 → A LLM 응답.
3. 번역/보정 대기 중 reset → 이전 응답, reset 직후 새 요청 → 이전 응답.
4. 보정 끄기 또는 키 교체 → 기존 보정 응답.
5. 같은 문자열·다른 발화 ID는 각각 보정, 같은 발화 ID의 중복 final은 한 번만 보정.
6. 언어쌍 변경과 유지 시간 만료 뒤 늦은 응답.

`refinedIDs`는 최근 중복 final 방지용이다. 오래된 전사 이벤트 폐기는 Task 5가 담당한다.
애니메이션도 동일한 표시 revision 검사를 거쳐야 한다.

- [ ] **Step 6: Google 흔적이 없는지 확인**

Run: `grep -rn "googleapis\|translate_a\|gtx" Sources/`
Expected: 출력 없음

- [ ] **Step 7: 오프라인 스모크**

1. `./run.sh` 로 실행.
2. Wi-Fi 를 끈다.
3. 한국어로 말한다 → 번역이 나와야 한다.
4. 번역이 안 나오면 언어팩 미설치다. 시스템 설정 → 일반 → 언어 및 지역 → 번역 언어에서
   한국어·영어를 받는다. (Task 7이 언어팩 다운로드를 앱 안으로 옮긴다.)
5. Wi-Fi 를 다시 켠다.

- [ ] **Step 8: 커밋**

```bash
git add -A
git commit -m "feat: replace Google gtx endpoint with on-device Translation

Captions no longer leave the machine and translation works offline.
The refiner hook is in place but unused until the Claude refiner lands;
it fires only on final transcripts so captions do not flicker.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 7: SwiftUI 자막 뷰로 이주

스펙 §6.6. 시각 디자인은 기준 커밋을 그대로 유지한다. 바뀌는 건 렌더링 방식뿐이다.

**Files:**
- Create: `Sources/LiveBilingualCaptions/CaptionState.swift`, `Sources/LiveBilingualCaptions/CaptionOverlay.swift`
- Modify: `Sources/LiveBilingualCaptions/main.swift` → `AppDelegate.swift` 로 분리, 라벨·버튼 제약 코드 제거

**Interfaces:**
- Consumes: `Transcript`, `CaptionLanguage`, `Settings`, `Translator`, `SpeechPipeline`
- Produces:
  - `@Observable @MainActor final class CaptionState` — `original: String`, `translated: String`, `status: String`, `fontSize: Double`, `isRunning: Bool`, `sourceLanguage: CaptionLanguage`, `targetLanguage: CaptionLanguage`, `translatedIsRefined: Bool`
  - `struct CaptionOverlay: View` — `init(state: CaptionState, onToggle:, onClear:, onCycleLanguage:, onQuit:)`

- [ ] **Step 1: `CaptionState` 작성**

`Sources/LiveBilingualCaptions/CaptionState.swift`:
```swift
import SwiftUI
import CaptionsCore

@Observable
@MainActor
final class CaptionState {
    var original = "말을 시작하면 원문이 여기에 표시됩니다"
    var translated = "번역이 여기에 표시됩니다"
    var status = "준비 중…"
    var fontSize: Double = 20
    var isRunning = false
    var translatedIsRefined = false
    var sourceLanguage: CaptionLanguage = .korean
    var targetLanguage: CaptionLanguage = .english

    func clear() {
        original = ""
        translated = ""
        translatedIsRefined = false
    }
}
```

- [ ] **Step 2: `CaptionOverlay` 작성**

기준 커밋의 수치를 그대로 옮긴다: 원문 20pt semibold 흰색, 번역 16pt medium 흰색 72%,
상태 12pt 흰색 52%, 좌우 여백 26, 줄 간격 7, 최대 2줄, 가운데 정렬, 코너 반경 20.

`Sources/LiveBilingualCaptions/CaptionOverlay.swift`:
```swift
import SwiftUI
import Translation
import CaptionsCore

struct CaptionOverlay: View {
    @Bindable var state: CaptionState
    var onToggle: () -> Void
    var onClear: () -> Void
    var onCycleLanguage: () -> Void
    var onQuit: () -> Void

    /// 언어팩이 없으면 이 설정이 non-nil 이 되고, .translationTask 가 다운로드 시트를 띄운다.
    /// 접근안 C 를 택한 이유가 이 한 줄이다.
    @State private var downloadConfiguration: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 7) {
            Text(state.original)
                .font(.system(size: state.fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text(state.translated)
                .font(.system(size: state.fontSize * 0.8, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.2), value: state.translated)

            HStack {
                Text(state.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer()
                Button(state.sourceLanguage.displayName, action: onCycleLanguage)
                Button(state.isRunning ? "정지" : "시작", action: onToggle)
                Button("지우기", action: onClear)
                Button("종료", action: onQuit)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
        .translationTask(downloadConfiguration) { session in
            // 시트에서 사용자가 받기를 누르면 여기가 완료된다.
            try? await session.prepareTranslation()
            downloadConfiguration = nil
        }
        .task(id: "\(state.sourceLanguage.id)-\(state.targetLanguage.id)") {
            await requestPackIfNeeded()
        }
    }

    private func requestPackIfNeeded() async {
        let status = await LanguageAvailability().status(
            from: state.sourceLanguage.locale.language,
            to: state.targetLanguage.locale.language)
        if status == .supported {
            downloadConfiguration = TranslationSession.Configuration(
                source: state.sourceLanguage.locale.language,
                target: state.targetLanguage.locale.language)
        }
    }
}
```

- [ ] **Step 3: `main.swift` 를 `main.swift` + `AppDelegate.swift` 로 분리**

`Sources/LiveBilingualCaptions/main.swift` — 진입점만 남긴다:
```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

이 단계에서는 최상위 코드가 있는 `main.swift`로 진입점을 통일하고 기존 `@main` 선언은 제거한다.
Task 1에서 `AppMain.swift`로 옮겼다면 중복 진입점이 남지 않도록 해당 파일도 함께 정리한다.
SwiftPM의 `@main` 감지 동작과 수동 swiftc 호출을 혼동하지 않는다.

- [ ] **Step 3a: 실행 타깃 Swift 6 전환**

`AppDelegate`를 `@MainActor`로 선언하고 `Package.swift`의 실행 타깃을 `.swiftLanguageMode(.v6)`으로
바꾼다. NotificationCenter·오디오·URLSession·애니메이션 콜백의 actor 경계를 각각 정리한다.
`.main` 큐 지정만으로 컴파일러의 actor 격리가 보장된다고 가정하지 않는다. 비격리 콜백에서
UI 변경은 `Task { @MainActor in ... }`로 전달하고, Sendable이 아닌 오디오 버퍼를 그대로 넘기지 않는다.
`@unchecked Sendable`로 오류를 일괄 억제하지 않는다. 이전 타깃의 Swift 5 예외는 이 단계에서 제거한다.

`Sources/LiveBilingualCaptions/AppDelegate.swift` — 나머지 전부. 창 생성은 이렇게 바뀐다:

```swift
private func buildWindow() {
    // 저장값의 유효 범위와 화면 맞춤은 Task 9의 restorePanelFrame에서 처리한다.
    let size = NSSize(width: settings.panelWidth ?? 560, height: settings.panelHeight ?? 188)
    panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
    // 발표·전체화면 위에도 자막이 보여야 한다.
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true

    // SwiftUI 는 내용만 그린다. 창 자체는 AppKit 이 잡는다 —
    // SwiftUI Scene 으로는 .screenSaver borderless 오버레이를 만들 수 없다.
    let overlay = CaptionOverlay(
        state: state,
        onToggle: { [weak self] in self?.toggleListening() },
        onClear: { [weak self] in self?.clearCaptions() },
        onCycleLanguage: { [weak self] in self?.cycleLanguage() },
        onQuit: { [weak self] in self?.quitApp() })
    let hosting = NSHostingView(rootView: overlay)
    hosting.frame = NSRect(origin: .zero, size: size)
    panel.contentView = hosting

    if let screen = NSScreen.main {
        let x = settings.panelOriginX ?? (screen.visibleFrame.midX - size.width / 2)
        let y = settings.panelOriginY ?? (screen.visibleFrame.minY + 54)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    panel.orderFrontRegardless()
}
```

`NSTextField`·`NSButton` 프로퍼티와 `NSLayoutConstraint.activate` 블록(기준 커밋 108–134줄)을
전부 삭제하고, 라벨에 쓰던 대입을 `state.original = …` 형태로 바꾼다.

- [ ] **Step 4: 빌드 확인**

Run: `./build.sh`
Expected: 성공. 이 단계 이후 실행 타깃도 Swift 6 모드로 빌드돼야 한다.

- [ ] **Step 5: 수동 스모크**

Run: `./run.sh`
확인 항목:
1. 패널이 기준 커밋과 **시각적으로 같아 보이는지** (HUD 재질, 글자 크기, 버튼 배치).
2. 빈 곳 드래그로 창이 움직이는지 (`isMovableByWindowBackground`).
3. 전체화면 앱 위에 자막이 뜨는지.
4. **언어팩이 없는 언어쌍에서 다운로드 시트가 뜨는지.** 확인하려면 시스템 설정에서
   기존 번역 언어를 지운 뒤 앱을 재실행한다. 이게 접근안 C 의 핵심 검증 항목이다.

- [ ] **Step 6: 커밋**

```bash
git add -A
git commit -m "feat: render captions with SwiftUI inside the NSPanel

The window stays AppKit because SwiftUI scenes cannot make a
screenSaver-level borderless overlay. Hosting SwiftUI content buys the
.translationTask modifier, which prompts for missing language packs
instead of silently showing no translation.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 8: 시스템 오디오 소스와 소스 전환

스펙 §6.1 의 두 번째 구현. 이 태스크로 "회의 모드" 문구가 사실이 된다.

**Files:**
- Create: `Sources/CaptionsCore/SystemAudioSource.swift`, `Sources/CaptionsCore/FormatGate.swift`, `Tests/CaptionsCoreTests/SystemAudioSourceTests.swift`, `Tests/CaptionsCoreTests/FormatGateTests.swift`
- Modify: `Sources/LiveBilingualCaptions/AppDelegate.swift`, `Sources/LiveBilingualCaptions/CaptionOverlay.swift`

**Interfaces:**
- Consumes: `AudioSource`, `AudioSourceError` (Task 4), `AudioSourceKind` (Task 3)
- Produces: `@MainActor SystemAudioSource: AudioSource`, 별도 `SCStreamOutput`/`SCStreamDelegate` 어댑터, 취소 가능한 `FormatGate`

- [ ] **Step 1: `SystemAudioSource` 작성**

`SCStream` 은 `CMSampleBuffer` 를 주므로 `AVAudioPCMBuffer` 로 바꿔야 한다.

기존의 `startCapture()` 후 continuation 등록 코드는 첫 버퍼가 먼저 오면 영원히 대기하므로
삭제했다. 아래 시작/정지 계약을 구현하고 가짜 콜백으로 검증한 뒤 실제 SCStream에 연결한다.

- `@MainActor SystemAudioSource`가 스트림의 시작·정지를 관리한다. `SCStreamOutput`과
  `SCStreamDelegate` 콜백은 별도 어댑터로 분리한다. sample queue에서 MainActor 프로퍼티를
  직접 수정하지 않는다. 콜백 데이터는 그 큐에서 PCM 복사·변환하고, 오류/상태만 안전하게 전달한다.
- 시작마다 새로운 실행 토큰과 일회성 `FormatGate`를 생성한다. gate는 `pending / resolved(Result)`
  상태이며 **결과를 먼저 받아도 저장한다.** wait 등록이 나중이면 저장된 결과를 즉시 반환한다.
  lock 또는 단일 actor로 상태를 보호하고 continuation은 정확히 한 번만 재개한다.
- gate와 sink를 설정한 뒤 `startCapture()`를 호출한다. 첫 유효 오디오 버퍼로 포맷을 결정한다.
  캡처 시작 실패·delegate 오류·취소·정지·5초 내 첫 버퍼 미도착도 gate를 오류로 완료한다.
  `withTaskCancellationHandler`의 onCancel은 gate 대기를 즉시 해제한다.
- 무음에서 첫 버퍼가 오지 않아도 무한 대기하지 않는다. 제한 시간 종료 시 스트림을 정리하고
  `오디오 입력을 기다리다 중단했습니다. 재생 후 다시 시작하세요`를 표시한다.
- `start()`는 `startCapture()` 성공과 첫 포맷 확보를 모두 확인한 후 반환한다. 반환 전에
  실행 토큰을 검사한다. 실패하면 해당 스트림의 `stopCapture()`까지 기다린다.
- `stop() async`는 먼저 토큰을 무효화하고 gate를 CancellationError로 완료하고 sink를 차단한 뒤
  `stopCapture()`를 await한다. 이전 스트림 콜백은 토큰으로 버린다. 다음 시작은 새 gate와 포맷을 쓴다.
- 설정: `capturesAudio = true`, `excludesCurrentProcessAudio = true`, `sampleRate = 48_000`,
  `channelCount = 2`. 실제 콜백 포맷이 설정과 다르면 실제 포맷을 변환기에 전달한다.
- 버퍼가 유효하고 `numSamples > 0`인지 확인한다. `AVAudioPCMBuffer`를 할당한 뒤
  `sampleBuffer.copyPCMData(fromRange: 0..<sampleBuffer.numSamples, into: buffer.mutableAudioBufferList)`로
  복사한다. 변환 실패를 조용히 삼키지 않고 현재 실행 오류로 전달한다.

- [ ] **Step 1a: 시작 경합 테스트**

`SystemAudioSourceTests.swift` / `FormatGateTests.swift`에 다음을 추가한다:
결과가 wait보다 먼저 도착, wait 후 첫 버퍼 도착, 무음 제한 시간, 시작 실패,
대기 중 정지/취소, stop과 첫 버퍼 동시 도착, 같은 소스 재시작, 이전 토큰 콜백 도착.
시계를 주입하고 gate를 수동으로 완료해 실제 5초 sleep 없이 검증한다.
모든 경로에서 대기가 종료되고 continuation 중복 재개가 없어야 한다.

- [ ] **Step 2: 빌드 확인**

Run: `swift build --package-path .`
Expected: 성공. 실패하면 `copyPCMData` 의 시그니처를 다음으로 확인한다:
`grep -rn "copyPCMData" /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreMedia.framework/`

- [ ] **Step 3: `AppDelegate` 에 소스 전환 배선**

```swift
private func makeSource() -> AudioSource {
    switch settings.audioSource {
    case .microphone: MicSource()
    case .systemAudio: SystemAudioSource()
    }
}

private func cycleAudioSource() {
    var updated = settings
    updated.audioSource = settings.audioSource == .microphone ? .systemAudio : .microphone
    apply(updated) // Step 5 controller와 Task 9의 단일 설정 적용 경로
}
```

`makeSource()`는 controller가 configuration의 소스 종류로 새 Run을 만들 때 사용한다.
`apply`의 최소 버전을 이 태스크에서 먼저 연결하고 Task 9에서 모든 설정으로 확장한다.
현재 listening뿐 아니라 starting 중 변경에도 마지막 configuration만 적용한다.

- [ ] **Step 4: `CaptionOverlay` 에 소스 버튼 추가**

`onCycleLanguage` 옆에 `onCycleAudioSource: () -> Void` 파라미터를 추가하고
버튼 행 맨 앞에 넣는다:
```swift
Button(state.audioSourceName, action: onCycleAudioSource)
```
`CaptionState` 에 `var audioSourceName = "마이크"` 를 추가하고 `cycleAudioSource()` 에서 갱신한다.

- [ ] **Step 5: 수동 스모크**

Run: `./run.sh`
1. 소스 버튼을 눌러 "시스템 오디오" 로 바꾼다.
2. 화면 기록 권한 요청이 뜨면 허용하고 **앱을 재실행**한다 (TCC 는 재시작을 요구한다).
3. YouTube 영어 영상을 재생한다 → 자막이 나와야 한다.
4. 소스를 "마이크" 로 되돌리고 직접 말한다 → 자막이 나와야 한다.
5. 시스템 오디오 모드에서 앱 자신의 소리가 되먹히지 않는지 확인
   (`excludesCurrentProcessAudio`).

권한이 매번 초기화되면 Task 1 Step 8 의 자체서명 인증서가 없는 것이다. `CLAUDE.md` 참고.

- [ ] **Step 6: 커밋**

```bash
git add -A
git commit -m "feat: capture system audio via ScreenCaptureKit

The meeting-mode label in the status line is now true: captions can
follow the other side of a call, not just the local microphone. Kept as
a separate AudioSource implementation so microphone-only use does not
require screen recording permission.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 9: 설정 창과 영속 배선

스펙 §6.5. 여기서 "매 실행 초기화" 문제가 사라진다.

**Files:**
- Create: `Sources/LiveBilingualCaptions/SettingsView.swift`
- Modify: `Sources/LiveBilingualCaptions/AppDelegate.swift`

**Interfaces:**
- Consumes: `Settings`, `AudioSourceKind`, `LanguageMode`, `DetectorSensitivity` (Task 3), `LanguageTable` (Task 2)
- Produces: `struct SettingsView: View`, `AppDelegate.showSettings()`

- [ ] **Step 1: `SettingsView` 작성**

`Sources/LiveBilingualCaptions/SettingsView.swift`:
```swift
import SwiftUI
import CaptionsCore

struct SettingsView: View {
    @Binding var settings: Settings
    var table: LanguageTable
    var availability: LanguageAvailabilityState

    var body: some View {
        Form {
            Section("오디오") {
                Picker("입력", selection: $settings.audioSource) {
                    ForEach(AudioSourceKind.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("음성 감지 민감도", selection: $settings.detectorSensitivity) {
                    ForEach(DetectorSensitivity.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
            Section("언어") {
                Picker("인식 언어", selection: languageSelection) {
                    Text("자동 (실험)").tag("auto")
                    ForEach(table.languages) {
                        Text($0.displayName).tag($0.id)
                            .disabled(availability.disabledLanguageIDs.contains($0.id))
                    }
                }
                Text("자동 모드는 잘못 인식된 문장으로 언어를 판단할 수 있습니다. 정확한 전환은 언어를 직접 선택하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                if table.languages.count >= 3 {
                    Picker("기본 번역 대상", selection: $settings.preferredTargetID) {
                        Text("첫 번째 다른 언어").tag(nil as String?)
                        ForEach(table.languages) {
                            Text($0.displayName).tag(Optional($0.id))
                                .disabled(availability.disabledTargetIDs.contains($0.id))
                        }
                    }
                }
            }
            Section("자막") {
                Slider(value: $settings.fontSize, in: 14...40, step: 1) {
                    Text("글자 크기 \(Int(settings.fontSize))pt")
                }
                Slider(value: $settings.captionHoldSeconds, in: 3...30, step: 1) {
                    Text("유지 시간 \(Int(settings.captionHoldSeconds))초")
                }
            }
            // "번역 보정" 섹션은 Task 10이 추가한다. updateRefiner()가 아직 없으므로
            // 여기서 토글을 노출하면 동작하지 않는 스위치가 되고 apply()가 컴파일되지 않는다.
        }
        .formStyle(.grouped)
        .frame(width: 420)
        // Binding setter가 변경 전후 비교와 apply를 수행한다. 별도 onChange로 다시 적용하지 않는다.
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: {
                switch settings.languageMode {
                case .auto: "auto"
                case .fixed(let id): id
                }
            },
            set: { settings.languageMode = $0 == "auto" ? .auto : .fixed($0) })
    }
}
```

- [ ] **Step 2: `AppDelegate` 에 설정 창과 메뉴바 아이템 추가**

`LSUIElement` 앱이라 Dock 아이콘이 없으므로 메뉴바에서 연다.

```swift
private var statusItem: NSStatusItem?
private var settingsWindow: NSWindow?

// Observation import 필요. 설정을 직접 대입하는 경로는 apply 하나뿐이다.
@Observable @MainActor
final class SettingsStore {
    var value = Settings.load(from: .standard)
}
private let settingsStore = SettingsStore()
private var settings: Settings { settingsStore.value }

private func buildStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "자막"
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "설정…", action: #selector(showSettings), keyEquivalent: ","))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q"))
    menu.items.forEach { $0.target = self }
    item.menu = menu
    statusItem = item
}

@objc func showSettings() {
    if let settingsWindow {
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    let view = SettingsView(
        settings: Binding(get: { self.settings }, set: { self.apply($0) }),
        table: .default,
        availability: availability)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Live Bilingual Captions 설정"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow = window
}

private func apply(_ new: Settings) {
    let old = settings // Binding setter가 이전 값을 덮어쓰기 전에 비교한다.
    guard old != new else { return }
    let captureChanged = old.audioSource != new.audioSource
        || old.languageMode != new.languageMode
        || old.detectorSensitivity != new.detectorSensitivity
    let pairChanged = old.preferredTargetID != new.preferredTargetID
        || old.languageMode != new.languageMode
    settingsStore.value = new
    new.save(to: .standard)
    state.fontSize = new.fontSize
    state.audioSourceName = new.audioSource.displayName
    translator.preferredTargetID = new.preferredTargetID
    if captureChanged || pairChanged {
        invalidateCaptions()
    }
    if captureChanged {
        // stopped면 다음 시작용 설정만 갱신. starting/listening이면 직렬로 재구성한다.
        controller.requestReconfigure(configuration: currentConfiguration)
    }
    if pairChanged {
        refreshLanguagePairAvailability()
    }
    if old.captionHoldSeconds != new.captionHoldSeconds {
        rescheduleCaptionClear()
    }
    // refinementEnabled 분기는 Task 10이 updateRefiner()와 함께 추가한다.
}
```

`currentConfiguration`은 매번 새 settings에서 만든다. 최초 실행도 설정을 읽은 뒤 fontSize,
audioSourceName, 고정 언어, preferredTargetID, detectorSensitivity를 반영하고 controller를 구성한다.
`requestReconfigure`는 중지 중인 앱을 임의로 시작하지 않는다.
`rescheduleCaptionClear()`는 마지막 원문 갱신 시각부터 새 유지 시간을 계산하고 이미 만료됐으면
즉시 지운다. 타이머 종료 시에도 `translator.reset()`을 호출해 늦은 응답으로 다시 표시되지 않게 한다.

`refreshLanguagePairAvailability()`를 구현한다. 음성 locale 지원 여부와 번역의 **방향별** 상태를
조회한다. 고정 원문→선택 대상, 원문 후보→해결된 대상을 각각 판정한다.
`.unsupported`만 비활성화하고 `.supported`에는 다운로드 안내를 표시한다.
비동기 조회 결과도 세대로 관리해 이전 언어쌍의 결과가 새 선택지를 덮어쓰지 않게 한다.
`@Observable @MainActor LanguageAvailabilityState`에 `disabledLanguageIDs`, `disabledTargetIDs`,
다운로드 필요 언어쌍을 저장한다. AppDelegate의 `availability`와 SettingsView가 이 인스턴스를 공유한다.
조회 완료와 원문 언어 변경에 따라 갱신한다. 저장된 미지원 조합은 원문만 표시하고 설정 수정을 안내한다.
controller의 현행 청취/전사 이벤트를 받을 때 `state.sourceLanguage`를 갱신하고
`table.target(for:preferredID:)`로 `state.targetLanguage`도 갱신한다. 시작 전에는 저장 설정으로
초기화한다. 이 두 값이 Task 7의 언어팩 다운로드 작업 ID에 반영돼야 한다.

- [ ] **Step 3: 창 위치 저장 배선**

`applicationDidFinishLaunching` 에서 패널 이동 알림을 구독한다:
```swift
NotificationCenter.default.addObserver(
    forName: NSWindow.didMoveNotification, object: panel, queue: .main
) { [weak self] _ in
    Task { @MainActor [weak self] in
        guard let self, let frame = self.panel?.frame else { return }
        var updated = self.settings
        updated.panelOriginX = frame.origin.x
        updated.panelOriginY = frame.origin.y
        updated.panelWidth = frame.width
        updated.panelHeight = frame.height
        self.apply(updated)
    }
}
```

panel은 MainActor Task 안에서만 읽는다. 이동뿐 아니라 `NSWindow.didResizeNotification`도
같은 처리로 구독하고 observer token을 보관했다가 종료 시 해제한다.
패널을 크기 조절 가능하게 만들고 Task 7의 초기 크기에 더해 `restorePanelFrame`으로 복원한다.
width/height가 유한한지 검사하고 최소 560×188부터 현재 화면 visibleFrame까지 제한한다.
화면이 최소 크기보다 작으면 보이는 영역을 우선한다. 위치도 연결된 화면 안으로 보정한다.
폰트 40pt에서 내용이 잘리지 않는 최소 높이를 계산한다. 복원 후 알림을 구독해 초기값 덮어쓰기를 막는다.

- [ ] **Step 4: 자막 유지 시간을 설정에서 읽도록 수정**

기준 커밋 462줄의 하드코딩 `10.0` 을 `settings.captionHoldSeconds` 로 바꾼다.

- [ ] **Step 5: 수동 스모크**

Run: `./run.sh`
1. 메뉴바 "자막" → 설정 → 글자 크기를 바꾼다 → 자막에 **즉시** 반영되는지.
2. 창을 드래그해 옮긴다.
3. 종료 후 재실행 → **창 위치·크기·글자 크기·오디오 소스·언어·민감도·기본 대상이 유지되는지.**
4. 실행 중 고정 언어·감지 민감도·소스를 각각 바꿔 실제 새 configuration이 적용되는지.
5. 설정 창과 오버레이 소스 버튼 양쪽에서 변경해도 UI가 일치하고 변경당 재구성이 한 번인지.
6. 3개 언어에서 기본 대상/동일 언어 대체/미지원 비활성화가 맞는지. 디스플레이를 분리해도 창이 보이는지.

가짜 controller를 사용한 SettingsApplyTests도 추가한다. 이전 값과 새 값의 비교, 소스/언어/민감도 변경 시
재구성 1회, 폰트만 변경 시 재구성 0회, 중지 중 설정 변경 후 다음 시작, 초기 복원을 검증한다.

- [ ] **Step 6: 커밋**

```bash
git add -A
git commit -m "feat: add settings window with persistence

Window position, font size, audio source, language mode, detector
sensitivity and hold time now survive a restart. Menu bar item because
LSUIElement leaves no dock icon to click.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 10: Claude 보정 (옵션, 기본 꺼짐)

스펙 §6.3 의 2단. **이 태스크를 건너뛰어도 앱은 완전히 동작한다.**

**Files:**
- Create: `Sources/CaptionsCore/KeychainStore.swift`, `Sources/CaptionsCore/ClaudeRefiner.swift`, `Tests/CaptionsCoreTests/KeychainStoreTests.swift`
- Modify: `Sources/LiveBilingualCaptions/AppDelegate.swift`, `Sources/LiveBilingualCaptions/SettingsView.swift`

**Interfaces:**
- Consumes: `TranslationRefiner` (Task 6)
- Produces:
  - `public enum KeychainStore` — `static func save(_ value: String, account: String) -> Bool`, `static func read(account: String) -> String?`, `static func delete(account: String)`, `static let apiKeyAccount = "anthropic.api-key"`
  - `public struct ClaudeRefiner: TranslationRefiner` — `init(apiKey: String, model: String)`

- [ ] **Step 0: `claude-api` 스킬을 로드한다**

**이 단계를 건너뛰지 않는다.** 모델 ID·엔드포인트·헤더·파라미터를 기억으로 쓰지 않는다.
`Skill` 도구로 `claude-api` 를 로드하고, 그 문서가 말하는 현재 값으로
아래 Step 3 의 `model`, `anthropic-version`, 요청 본문을 **덮어쓴다.**
자막은 지연에 민감하므로 최저지연 모델(Haiku 계열)을 고른다.

- [ ] **Step 1: Keychain 테스트 작성**

`Tests/CaptionsCoreTests/KeychainStoreTests.swift`:
```swift
import Testing
import Foundation
@testable import CaptionsCore

@Test func 저장하고_읽고_지운다() {
    let account = "test.\(UUID().uuidString)"
    defer { KeychainStore.delete(account: account) }

    #expect(KeychainStore.read(account: account) == nil)
    #expect(KeychainStore.save("비밀값", account: account) == true)
    #expect(KeychainStore.read(account: account) == "비밀값")
    #expect(KeychainStore.save("바뀐값", account: account) == true)
    #expect(KeychainStore.read(account: account) == "바뀐값")
    KeychainStore.delete(account: account)
    #expect(KeychainStore.read(account: account) == nil)
}
```

- [ ] **Step 2: 테스트 실패 확인 후 `KeychainStore` 구현**

Run: `./test.sh` → FAIL (`cannot find 'KeychainStore'`)

`Sources/CaptionsCore/KeychainStore.swift`:
```swift
import Foundation
import Security

/// API 키 보관소. UserDefaults·소스코드·환경변수에 키를 두지 않는다.
public enum KeychainStore {
    public static let apiKeyAccount = "anthropic.api-key"
    private static let service = "local.codex.LiveBilingualCaptions"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    public static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func read(account: String) -> String? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
```

Run: `./test.sh` → PASS

- [ ] **Step 3: `ClaudeRefiner` 구현**

**Step 0 에서 로드한 `claude-api` 스킬의 값으로 아래 상수를 맞춘다.**

`Sources/CaptionsCore/ClaudeRefiner.swift`:
```swift
import Foundation

/// 확정된 문장의 온디바이스 번역을 문맥을 보고 다듬는다.
/// 부분 전사에는 절대 호출되지 않는다 — Translator 가 보장한다.
public struct ClaudeRefiner: TranslationRefiner {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func refine(_ draft: String, source: String, context: [String]) async throws -> String {
        let contextBlock = context.isEmpty ? "(없음)" : context.joined(separator: "\n")
        let prompt = """
        실시간 자막의 기계 번역을 다듬어라.

        직전 문장들:
        \(contextBlock)

        원문: \(source)
        기계 번역: \(draft)

        자연스럽게 고친 번역문만 출력하라. 설명·따옴표·접두어를 붙이지 마라.
        내용을 추가하거나 빼지 마라. 고칠 것이 없으면 기계 번역을 그대로 출력하라.
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 6          // 자막이므로 오래 기다리지 않는다
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 300,
            "messages": [["role": "user", "content": prompt]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "ClaudeRefiner", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "보정 요청 실패"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw NSError(domain: "ClaudeRefiner", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "보정 응답을 해석하지 못했습니다"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 3a: Task 9가 미뤄둔 보정 UI와 분기를 추가**

Task 9는 `updateRefiner()` 가 없어 이 둘을 넣지 않았다. 지금 함께 넣는다.

`SettingsView` 에 섹션을 추가한다:
```swift
Section("번역 보정") {
    Toggle("Claude 로 확정 문장 다듬기", isOn: $settings.refinementEnabled)
    Text("켜면 확정된 문장만 인터넷으로 전송됩니다. 끄면 모든 처리가 기기 안에서 끝납니다.")
        .font(.caption).foregroundStyle(.secondary)
}
```

`AppDelegate.apply(_:)` 에 분기를 추가한다:
```swift
if old.refinementEnabled != new.refinementEnabled { updateRefiner() }
```

- [ ] **Step 4: 설정 창에 API 키 입력란 추가**

`SettingsView` 의 "번역 보정" 섹션에 추가:
```swift
if settings.refinementEnabled {
    SecureField("Anthropic API 키", text: $apiKey)
        .onSubmit { saveAPIKey() }
    Button("키 저장", action: saveAPIKey)
    Text(keySaveStatus)
        .font(.caption).foregroundStyle(.secondary)
    Text("키는 Keychain 에 저장됩니다.")
        .font(.caption).foregroundStyle(.secondary)
}
```
`@State private var apiKey = KeychainStore.read(account: KeychainStore.apiKeyAccount) ?? ""` 를 추가한다.
아래 상태와 콜백도 `SettingsView`에 추가한다. 저장 성공 후에만 보정기를 갱신한다.

```swift
@State private var keySaveStatus = ""
var onAPIKeySaved: () -> Void

private func saveAPIKey() {
    let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
        keySaveStatus = "API 키를 입력하세요"
        return
    }
    guard KeychainStore.save(value, account: KeychainStore.apiKeyAccount) else {
        keySaveStatus = "키를 저장하지 못했습니다"
        return
    }
    keySaveStatus = "키를 저장했습니다"
    onAPIKeySaved()
}
```

`AppDelegate.showSettings()`의 생성자에
`onAPIKeySaved: { [weak self] in self?.updateRefiner() }`를 전달한다.
Step 2의 Keychain 구현은 갱신에 `SecItemUpdate`를 사용하고,
`errSecItemNotFound`일 때만 `SecItemAdd`를 호출한다.
실패 시 기존 키를 보존한다. 키 내용을 로그·오류 문구에 포함하지 않는다.

- [ ] **Step 5: `AppDelegate` 에서 보정기 연결**

```swift
private func updateRefiner() {
    guard settings.refinementEnabled,
          let key = KeychainStore.read(account: KeychainStore.apiKeyAccount),
          !key.isEmpty else {
        translator.refiner = nil
        return
    }
    translator.refiner = ClaudeRefiner(apiKey: key, model: refinerModel)
}
```
`applicationDidFinishLaunching`, `apply(_:)`의 보정 on/off 변경 분기, API 키 저장 성공 시 호출한다.
폰트·창 위치만 바뀌었을 때는 다시 연결하지 않는다. `Translator.refiner`의 didSet이
이전 보정 작업을 취소하고 응답 세대를 무효화한다.
`refinerModel` 은 Step 0 에서 확인한 모델 ID 상수다.

- [ ] **Step 6: 수동 스모크**

1. 설정에서 보정을 **끈 채로** 실행 → 자막·번역이 정상 동작하는지. **이게 기본 경로다.**
2. Wi-Fi 를 끈 상태로 보정을 켠다 → 보정만 실패하고 **자막은 계속 나와야 한다.**
3. 유효한 키를 넣고 보정을 켠다 → 확정 문장에서 번역이 한 번 교체되며 크로스페이드되는지.
   추가: 먼저 보정을 켠 뒤 처음 키를 저장해도 재토글·재실행 없이 다음 final에 적용되는지.
   요청 대기 중 보정을 끄거나 키를 교체해도 이전 응답이 표시되지 않는지.
4. **말하는 도중 번역이 깜빡이지 않는지.** 깜빡이면 스펙 §9 리스크 3 대로 이 태스크를 되돌린다:
   `git revert` 후 `refinementEnabled` 를 설정에서 제거한다.

- [ ] **Step 7: 커밋**

```bash
git add -A
git commit -m "feat: add optional Claude refinement for final captions

Off by default and gated behind a Keychain-stored key. Fires only on
final transcripts so partial captions never flicker, and a failed
refinement leaves the on-device translation standing.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 8: README 갱신**

기준 커밋 README 의 마지막 줄 "번역 요청의 문장이 Google 번역 서버로 전송됩니다" 는
이제 **거짓**이다. 다음으로 바꾼다:

```markdown
음성 인식과 번역은 모두 macOS 내장 기능으로 **기기 안에서** 처리됩니다.
설정에서 "Claude 로 확정 문장 다듬기" 를 켠 경우에만, 확정된 문장이 Anthropic API 로 전송됩니다.
이 기능은 기본적으로 꺼져 있습니다.
```

사용 안내에 오디오 소스 전환과 메뉴바 설정도 추가한다.

```bash
git add README.md
git commit -m "docs: update README for on-device processing

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-Review 결과

**1. 스펙 커버리지**

| 스펙 절 | 태스크 |
|---|---|
| §5 구조 | Task 1 |
| §6.1 오디오 계층 | Task 4 (마이크), Task 8 (시스템 오디오) |
| §6.2 인식 파이프라인 | Task 5 |
| §6.3 번역 2단 | Task 6 (1단), Task 10 (2단) |
| §6.4 언어 테이블 | Task 2 |
| §6.5 설정 | Task 3 (모델), Task 9 (UI·배선) |
| §6.6 UI | Task 7 |
| §8 테스트 | Task 2·3·5·6·10 의 TDD 단계 |
| §9 리스크 1 (권한 초기화) | Task 1 Step 8 + `CLAUDE.md` |
| §9 리스크 3 (깜빡임) | Task 10 Step 6 항목 4 에 되돌리기 조건 명시 |
| §9 리스크 4 (모델 다운로드) | Task 5 `PipelineEvent.installing` |
| §9 리스크 5 (번들 조립) | Task 1 Step 8 |
| §10 0단계 (CLAUDE.md·보드) | Task 1 Step 11·12 |

최초 자체 검토의 '누락 없음' 판정은 철회한다. 검토 수정으로 대상 언어 설정·미지원 조합·
창 크기 영속을 추가했고, 각 항목의 완료 여부는 아래 실행 검증으로 판단한다.

**2. 코드 예시의 범위** — 순수 로직·번역·설정에는 구체적인 코드 예시가 있다.
Task 5의 변환·제어 흐름과 Task 8의 캡처 시작은 경합이 있던 예시를 제거하고 구현 계약으로 교체했다.
이 부분은 계약에 맞춘 구현과 회귀 테스트가 남아 있으며 '그대로 복사하면 완성'이라고 주장하지 않는다.

**3. 테스트 범위** — 고정된 누적 개수 대신 아래 필수 범위를 검증하고 실제 실행 개수를 기록한다.

| 태스크 | 필수 검증 |
|---|---|
| Task 1 | SPM 빌드·테스트 하네스, 타깃별 Swift 모드 |
| Task 2·3 | 문자열 분류, 3언어 대상 선택, 설정 호환·크기 복원 |
| Task 5 | PCM 변환, 실행 취소·오류 정리·이전 이벤트 폐기, 발화 ID |
| Task 6 | final 한정 보정, 응답 역전·취소 무시·세대 무효화 |
| Task 7 | 실행 타깃 Swift 6 빌드, 실제 언어팩 다운로드 UI |
| Task 8 | 첫 버퍼 선도착·무음·시작 실패·취소·재시작 |
| Task 9 | 설정 변경 전후 비교, 실제 적용, 미지원 조합·창 크기 복원 |
| Task 10 | Keychain 보존 갱신, 키 저장 즉시 연결, 보정 해제 후 응답 폐기 |

**4. 타입 일관성** — 태스크 간 사용 이름을 대조했다.
`CaptionLanguage.id`(Task 2) → Task 3 `LanguageMode.fixed(String)`, Task 9 Picker tag 에서 동일하게 사용.
`AudioSource.start`는 캡처 포맷 반환, `stop`은 async(Task 4·8). Task 5는 변환된 분석 포맷으로 prepare한다.
`Transcript`(Task 5) → Task 6 `Translator.handle` 이 동일 타입 수신.
`TranslationRefiner.refine(_:source:context:)`(Task 6) → Task 10 `ClaudeRefiner` 가 동일 시그니처 구현.
`Settings.refinementEnabled`(Task 3) → Task 9 Toggle, Task 10 `updateRefiner()` 에서 동일.
문서 정합 검토와 실제 Swift 빌드는 별개다. 전체 예시 통합은 각 태스크의 빌드 게이트에서 확인한다.

**5. 검토 중 고친 결함 1건** — Task 6 의 초안은 `Translator` 가 `TranslationSession` 을
직접 만들어 쓰게 되어 있었다. 그러면 테스트가 **이 머신의 언어팩 설치 상태에 따라
통과하기도 실패하기도 한다.** 번역을 `TranslateFunction` 으로 주입 가능하게 바꾸고
테스트는 가짜를 넣도록 고쳤다. 앱 경로는 기본값 `Translator.onDevice` 를 그대로 쓴다.

**6. 이번 문서 수정에서 실행한 검증 (2026-09-16)**

- `git diff --check`, 코드 펜스 짝, Task 1–10 순서 검사 통과.
- 문서에서 `LanguageTable`, `Settings`, `Transcript`, `Translator` 예시를 추출해
  `swiftc -typecheck -swift-version 6` 통과.
- 같은 예시를 가짜 번역기와 함께 컴파일·실행해 응답 역전 시 이전 결과 폐기,
  reset 후 취소를 무시한 응답 폐기, 3개 언어의 기본 대상 선택·대체 동작 확인.
- 앱 전체 구현·마이크/시스템 캡처·언어팩 UI·설정 창 통합은 실행하지 않았다.
  이 검증은 해당 예시에 한정되며 각 태스크의 구현 완료 체크를 대신하지 않는다.
