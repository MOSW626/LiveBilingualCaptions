# Live Bilingual Captions 재작성 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 단일 파일 AppKit 자막 앱을, 마이크·시스템 오디오를 전환하며 macOS 26 온디바이스 인식·번역으로 양국어 자막을 띄우는 SPM 기반 SwiftUI 앱으로 재작성한다.

**Architecture:** `CaptionsCore`(UI 없는 라이브러리, 테스트 대상)와 `LiveBilingualCaptions`(실행 파일) 2타깃. 오디오는 `AudioSource` 프로토콜의 두 구현(마이크 / 시스템 오디오)이 `AVAudioPCMBuffer`를 흘려보내고, `SpeechAnalyzer` 파이프라인이 부분/확정 전사로 바꾸고, `Translator`가 온디바이스 번역(+옵션 LLM 보정)을 붙여, `NSPanel` 안의 SwiftUI 뷰가 그린다.

**Tech Stack:** Swift 6.3 / SwiftPM (tools-version 6.2) / macOS 26 / Speech(`SpeechAnalyzer`·`SpeechTranscriber`·`SpeechDetector`) / Translation(`TranslationSession`·`.translationTask`) / ScreenCaptureKit / AppKit + SwiftUI(`NSHostingView`) / swift-testing

**Spec:** `docs/superpowers/specs/2026-09-16-live-bilingual-captions-design.md`

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
- **번역·인식은 기본적으로 오프라인 동작해야 한다.** 네트워크는 Task 10 의 옵션 기능에서만 쓴다.
- **모든 사용자 노출 문자열은 한국어.** 기준 커밋의 문구 톤을 따른다.
- **각 태스크 종료 시 앱이 빌드되고 실행돼야 한다.** 중간에 멈춰도 쓸 수 있는 상태를 남긴다.

### 검증된 API 시그니처 (2026-09-16, 실제 typecheck 통과)

아래는 추측이 아니라 `swiftc -typecheck` 로 함께 컴파일해 확인한 형태다. 그대로 쓴다.

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
| `Sources/CaptionsCore/Debouncer.swift` | 번역 호출 디바운스 |
| `Sources/CaptionsCore/Transcript.swift` | 부분/확정 전사 타입 |
| `Sources/CaptionsCore/AudioSource.swift` | `AudioSource` 프로토콜 + `MicSource` |
| `Sources/CaptionsCore/SystemAudioSource.swift` | ScreenCaptureKit 시스템 오디오 |
| `Sources/CaptionsCore/SpeechPipeline.swift` | SpeechAnalyzer 구동, 언어 교체 |
| `Sources/CaptionsCore/Translator.swift` | 온디바이스 번역 + `TranslationRefiner` 훅 |
| `Sources/CaptionsCore/ClaudeRefiner.swift` | LLM 보정 구현 (옵션) |
| `Sources/CaptionsCore/KeychainStore.swift` | API 키 보관 |
| `Sources/LiveBilingualCaptions/main.swift` | `@main` 진입점 |
| `Sources/LiveBilingualCaptions/AppDelegate.swift` | NSPanel, 메뉴바 아이템, 파이프라인 배선 |
| `Sources/LiveBilingualCaptions/CaptionOverlay.swift` | SwiftUI 자막 뷰, `.translationTask` |
| `Sources/LiveBilingualCaptions/CaptionState.swift` | `@Observable` UI 상태 |
| `Sources/LiveBilingualCaptions/SettingsView.swift` | SwiftUI 설정 창 |
| `Tests/CaptionsCoreTests/*.swift` | 순수 로직 테스트 |

---

# Task 1: SPM 전환 + 테스트 하네스 + 번들 빌드

기존 동작을 **그대로 둔 채** 빌드 체계만 바꾼다. 이 태스크가 끝나면 앱은 기준 커밋과 똑같이 동작해야 한다.

**Files:**
- Create: `Package.swift`, `test.sh`, `Tests/CaptionsCoreTests/SmokeTests.swift`, `Sources/CaptionsCore/CaptionsCore.swift`, `CLAUDE.md`
- Modify: `build.sh` (전체 교체), `Info.plist` (`LSMinimumSystemVersion`)
- Move: `Sources/LiveBilingualCaptions/main.swift` 유지 (내용 변경 없음)

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
            dependencies: ["CaptionsCore"]
        ),
        .testTarget(
            name: "CaptionsCoreTests",
            dependencies: ["CaptionsCore"]
        )
    ]
)
```

`dependencies:` 를 Package 레벨에 두지 않는다 — 서드파티 의존성 금지.

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
  - `public struct LanguageTable: Sendable` — `languages: [CaptionLanguage]`, `static let `default`: LanguageTable`, `func detect(_ text: String, current: CaptionLanguage) -> CaptionLanguage`, `func target(for: CaptionLanguage) -> CaptionLanguage?`, `func language(id: String) -> CaptionLanguage?`
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
        locale: Locale(identifier: "en-US"), displayName: "English",
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

    /// 번역 대상 = 감지된 언어가 아닌 첫 번째 언어.
    public func target(for source: CaptionLanguage) -> CaptionLanguage? {
        languages.first { $0 != source }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `./test.sh`
Expected: 7개 테스트 전부 PASS

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

# Task 3: 자막 문자열 가공 · 설정 영속 · 디바운서

순수 로직 3종을 한 태스크로 묶는다. 셋 다 작고, 셋 다 이후 태스크가 즉시 쓴다.

**Files:**
- Create: `Sources/CaptionsCore/CaptionText.swift`, `Sources/CaptionsCore/Settings.swift`, `Sources/CaptionsCore/Debouncer.swift`, `Tests/CaptionsCoreTests/CaptionTextTests.swift`, `Tests/CaptionsCoreTests/SettingsTests.swift`, `Tests/CaptionsCoreTests/DebouncerTests.swift`

**Interfaces:**
- Consumes: `CaptionLanguage` (Task 2)
- Produces:
  - `public enum CaptionText { public static func tail(_ text: String, limit: Int = 92) -> String }`
  - `public enum AudioSourceKind: String, Codable, Sendable, CaseIterable { case microphone, systemAudio }`
  - `public enum LanguageMode: Equatable, Codable, Sendable { case auto, fixed(String) }`
  - `public enum DetectorSensitivity: String, Codable, Sendable, CaseIterable { case low, medium, high }`
  - `public struct Settings: Codable, Equatable, Sendable` — `languageMode`, `audioSource`, `fontSize`, `captionHoldSeconds`, `detectorSensitivity`, `refinementEnabled`, `panelOriginX`, `panelOriginY`; `static let `default``, `static func load(from: UserDefaults) -> Settings`, `func save(to: UserDefaults)`
  - `public actor Debouncer` — `init(interval: Duration)`, `func schedule(_ work: @escaping @Sendable () async -> Void)`, `func cancel()`

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

- [ ] **Step 3: 실패하는 테스트 작성 — 디바운서**

`Tests/CaptionsCoreTests/DebouncerTests.swift`:
```swift
import Testing
import Foundation
@testable import CaptionsCore

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}

@Test func 연속_호출은_마지막_한_번만_실행된다() async throws {
    let counter = Counter()
    let debouncer = Debouncer(interval: .milliseconds(50))
    for _ in 0..<5 {
        await debouncer.schedule { await counter.bump() }
        try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await counter.value == 1)
}

@Test func 간격을_두고_호출하면_각각_실행된다() async throws {
    let counter = Counter()
    let debouncer = Debouncer(interval: .milliseconds(30))
    await debouncer.schedule { await counter.bump() }
    try await Task.sleep(for: .milliseconds(120))
    await debouncer.schedule { await counter.bump() }
    try await Task.sleep(for: .milliseconds(120))
    #expect(await counter.value == 2)
}

@Test func 취소하면_실행되지_않는다() async throws {
    let counter = Counter()
    let debouncer = Debouncer(interval: .milliseconds(50))
    await debouncer.schedule { await counter.bump() }
    await debouncer.cancel()
    try await Task.sleep(for: .milliseconds(150))
    #expect(await counter.value == 0)
}
```

- [ ] **Step 4: 테스트 실패 확인**

Run: `./test.sh`
Expected: FAIL — `cannot find 'CaptionText' / 'Settings' / 'Debouncer' in scope`

- [ ] **Step 5: `CaptionText` 구현**

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

- [ ] **Step 6: `Settings` 구현**

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
    public var audioSource: AudioSourceKind
    public var fontSize: Double
    public var captionHoldSeconds: Double
    public var detectorSensitivity: DetectorSensitivity
    public var refinementEnabled: Bool
    public var panelOriginX: Double?
    public var panelOriginY: Double?

    public static let storageKey = "settings.v1"

    public static let `default` = Settings(
        languageMode: .auto,
        audioSource: .microphone,
        fontSize: 20,
        captionHoldSeconds: 10,
        detectorSensitivity: .medium,
        refinementEnabled: false,      // 네트워크·비용이 드는 기능은 기본 꺼짐
        panelOriginX: nil,
        panelOriginY: nil)

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

- [ ] **Step 7: `Debouncer` 구현**

`Sources/CaptionsCore/Debouncer.swift`:
```swift
import Foundation

/// 마지막 호출만 살린다. 부분 전사가 초당 여러 번 쏟아질 때 번역 호출을 줄이는 용도.
public actor Debouncer {
    private let interval: Duration
    private var pending: Task<Void, Never>?

    public init(interval: Duration) { self.interval = interval }

    public func schedule(_ work: @escaping @Sendable () async -> Void) {
        pending?.cancel()
        pending = Task { [interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}
```

- [ ] **Step 8: 테스트 통과 확인**

Run: `./test.sh`
Expected: 총 20개 PASS (Task 1 스모크 1 + Task 2 언어 7 + 이번 12)
(디바운서 테스트는 실제 시간을 쓰므로 느리다. 간헐적으로 실패하면 간격을 2배로 키운다.)

- [ ] **Step 9: 커밋**

```bash
git add Sources/CaptionsCore Tests/CaptionsCoreTests
git commit -m "feat: add caption text, settings persistence, and debouncer

Settings fall back to defaults on corrupt data so one bad value cannot
stop the app from launching. Debouncer keeps only the last call, which
is what partial transcripts need.

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
  - `public protocol AudioSource: AnyObject` — `func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat`, `func stop()`
  - `public final class MicSource: AudioSource`
  - `public enum AudioSourceError: LocalizedError` — `case noInput, permissionDenied, noDisplay`

- [ ] **Step 1: 프로토콜과 마이크 구현 작성**

`start` 가 포맷을 **반환**한다. `SpeechAnalyzer.prepareToAnalyze(in:)` 가 포맷을 먼저 요구하는데,
`SCStream` 은 스트림을 켜기 전에는 포맷을 모르기 때문이다.

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
public protocol AudioSource: AnyObject {
    /// 캡처를 시작하고 실제 오디오 포맷을 돌려준다.
    /// 포맷을 반환값으로 주는 이유: SCStream 은 켜기 전에 포맷을 알 수 없다.
    func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat
    func stop()
}

/// AVAudioEngine 마이크 입력. 마이크 권한만 필요하고 화면 기록 권한은 필요 없다.
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
        try engine.start()
        started = true
        return format
    }

    public func stop() {
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

start() returns the format because SCStream cannot report one until the
stream is running; the speech analyzer needs a format up front.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 5: 인식 파이프라인 교체 — 여기가 실제 개선

스펙 §6.2. 기준 커밋의 인식 코드 전부를 `SpeechAnalyzer` 로 갈아치운다.

**Files:**
- Create: `Sources/CaptionsCore/Transcript.swift`, `Sources/CaptionsCore/SpeechPipeline.swift`, `Tests/CaptionsCoreTests/TranscriptTests.swift`
- Modify: `Sources/LiveBilingualCaptions/main.swift` — `SFSpeechRecognizer` 경로 전부 제거 후 `SpeechPipeline` 배선

**Interfaces:**
- Consumes: `AudioSource`, `MicSource` (Task 4), `CaptionLanguage`, `LanguageTable` (Task 2), `DetectorSensitivity` (Task 3)
- Produces:
  - `public enum Transcript: Sendable, Equatable` — `case partial(String)`, `case final(String)`; `var text: String`, `var isFinal: Bool`
  - `public enum PipelineEvent: Sendable` — `case installing(Double)`, `case listening`, `case transcript(Transcript)`, `case failed(String)`
  - `@MainActor public final class SpeechPipeline` — `init(table: LanguageTable, sensitivity: DetectorSensitivity)`, `var onEvent: (@MainActor (PipelineEvent) -> Void)?`, `var currentLanguage: CaptionLanguage`, `func start(source: AudioSource, language: CaptionLanguage) async`, `func switchLanguage(to: CaptionLanguage) async`, `func stop() async`

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
Expected: 22개 PASS

- [ ] **Step 5: `SpeechPipeline` 구현**

`Sources/CaptionsCore/SpeechPipeline.swift`:
```swift
import Foundation
import Speech
import AVFoundation

public enum PipelineEvent: Sendable {
    case installing(Double)          // 0.0 ~ 1.0
    case listening
    case transcript(Transcript)
    case failed(String)
}

/// SpeechAnalyzer 한 개를 계속 살려두고, 언어가 바뀌면 모듈만 갈아끼운다.
/// 기준 커밋이 발화마다 SFSpeechRecognizer 를 새로 만들던 것을 대체한다.
@MainActor
public final class SpeechPipeline {
    private let table: LanguageTable
    private let sensitivity: DetectorSensitivity

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var detector: SpeechDetector?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var source: AudioSource?

    public private(set) var currentLanguage: CaptionLanguage = .korean
    public var onEvent: (@MainActor (PipelineEvent) -> Void)?

    public init(table: LanguageTable, sensitivity: DetectorSensitivity) {
        self.table = table
        self.sensitivity = sensitivity
    }

    private var detectorLevel: SpeechDetector.SensitivityLevel {
        switch sensitivity {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    private func makeTranscriber(for language: CaptionLanguage) async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            throw NSError(domain: "Captions", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "\(language.displayName) 전사 모델을 지원하지 않습니다"])
        }
        // 주의: SpeechTranscriber.TranscriptionOption 에는 .punctuation 이 없다.
        // 구두점은 preset 에서 온다.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = request.progress
            let reporter = Task { [weak self] in
                while !Task.isCancelled && !progress.isFinished {
                    let fraction = progress.fractionCompleted
                    await MainActor.run { self?.onEvent?(.installing(fraction)) }
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            try await request.downloadAndInstall()
            reporter.cancel()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        return transcriber
    }

    public func start(source: AudioSource, language: CaptionLanguage) async {
        do {
            self.source = source
            currentLanguage = language

            let transcriber = try await makeTranscriber(for: language)
            let detector = SpeechDetector(
                detectionOptions: .init(sensitivityLevel: detectorLevel),
                reportResults: false)
            self.transcriber = transcriber
            self.detector = detector

            let analyzer = SpeechAnalyzer(modules: [detector, transcriber])
            self.analyzer = analyzer

            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            self.continuation = continuation

            let format = try await source.start { buffer in
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
            try await analyzer.prepareToAnalyze(in: format)

            observeResults(of: transcriber)
            analysisTask = Task { [weak self] in
                do { _ = try await analyzer.analyzeSequence(stream) }
                catch {
                    await MainActor.run { self?.onEvent?(.failed("분석 오류: \(error.localizedDescription)")) }
                }
            }
            onEvent?(.listening)
        } catch {
            onEvent?(.failed("시작 실패: \(error.localizedDescription)"))
        }
    }

    private func observeResults(of transcriber: SpeechTranscriber) {
        resultsTask?.cancel()
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let transcript: Transcript = result.isFinal ? .final(text) : .partial(text)
                    await MainActor.run { self?.onEvent?(.transcript(transcript)) }
                }
            } catch {
                await MainActor.run { self?.onEvent?(.failed("전사 오류: \(error.localizedDescription)")) }
            }
        }
    }

    /// 오디오 입력을 끊지 않고 언어만 바꾼다. 기준 커밋처럼 엔진을 내렸다 올리지 않는다.
    public func switchLanguage(to language: CaptionLanguage) async {
        guard language != currentLanguage,
              let analyzer, let detector else { return }
        do {
            let transcriber = try await makeTranscriber(for: language)
            try await analyzer.setModules([detector, transcriber])
            self.transcriber = transcriber
            currentLanguage = language
            observeResults(of: transcriber)
            onEvent?(.listening)
        } catch {
            onEvent?(.failed("언어 전환 실패: \(error.localizedDescription)"))
        }
    }

    public func stop() async {
        source?.stop()
        source = nil
        continuation?.finish()
        continuation = nil
        analysisTask?.cancel(); analysisTask = nil
        resultsTask?.cancel(); resultsTask = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil; transcriber = nil; detector = nil
    }
}
```

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
private let pipeline = SpeechPipeline(table: .default, sensitivity: .medium)
private var recognitionLanguage: CaptionLanguage = .korean

private func startListening() {
    guard !running else { return }
    running = true
    toggleButton.title = "정지"
    pipeline.onEvent = { [weak self] event in self?.handle(event) }
    Task { await pipeline.start(source: MicSource(), language: recognitionLanguage) }
}

private func handle(_ event: PipelineEvent) {
    switch event {
    case .installing(let fraction):
        statusLabel.stringValue = "음성 모델 설치 중 · \(Int(fraction * 100))%"
    case .listening:
        statusLabel.stringValue = "● 듣는 중 · \(pipeline.currentLanguage.displayName)"
    case .transcript(let transcript):
        originalLabel.stringValue = CaptionText.tail(transcript.text)
        scheduleTranslation(of: transcript)
        if transcript.isFinal { adaptLanguage(from: transcript.text) }
    case .failed(let message):
        statusLabel.stringValue = message
        running = false
        toggleButton.title = "다시 시작"
    }
}

/// 확정 전사에서만 언어를 재판단한다. 부분 결과로 바꾸면 문장 도중에 언어가 튄다.
private func adaptLanguage(from text: String) {
    guard languageMode == .auto else { return }
    let detected = LanguageTable.default.detect(text, current: pipeline.currentLanguage)
    guard detected != pipeline.currentLanguage else { return }
    Task { await pipeline.switchLanguage(to: detected) }
}

private func stopListening() {
    Task { await pipeline.stop() }
    running = false
    toggleButton.title = "시작"
    statusLabel.stringValue = "일시 정지"
}
```

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
3. 영어로 한 문장 말한 뒤, 다음 발화에서 언어가 전환되는지.
4. 한국어↔영어를 오갈 때 오디오가 끊기지 않는지.

- [ ] **Step 9: 커밋**

```bash
git add -A
git commit -m "feat: replace SFSpeechRecognizer with SpeechAnalyzer pipeline

Deletes the hand-rolled RMS voice detection, the silence timer that
restarted recognition every utterance, and the confidence-threshold
language heuristic. SpeechDetector handles VAD and setModules swaps the
language without tearing down the audio tap. Language re-detection now
runs on final transcripts only, so it cannot flip mid-sentence.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Task 6: 온디바이스 번역으로 교체

스펙 §6.3 의 1단. Google `gtx` 엔드포인트를 제거한다.

**Files:**
- Create: `Sources/CaptionsCore/Translator.swift`, `Tests/CaptionsCoreTests/TranslatorTests.swift`
- Modify: `Sources/LiveBilingualCaptions/main.swift` — `translate(_:)` 463–489줄 제거, `Translator` 배선

**Interfaces:**
- Consumes: `CaptionLanguage`, `LanguageTable` (Task 2), `Debouncer` (Task 3), `Transcript` (Task 5)
- Produces:
  - `public protocol TranslationRefiner: Sendable { func refine(_ draft: String, source: String, context: [String]) async throws -> String }`
  - `public enum PackStatus: Sendable, Equatable { case installed, needsDownload, unsupported }`
  - `public typealias TranslateFunction = @Sendable (String, CaptionLanguage, CaptionLanguage) async -> String?`
  - `@MainActor public final class Translator` — `init(table: LanguageTable, translate: @escaping TranslateFunction = Translator.onDevice)`, `static let onDevice: TranslateFunction`, `var refiner: TranslationRefiner?`, `var onTranslation: (@MainActor (String, Bool) -> Void)?`, `static func packStatus(from:to:) async -> PackStatus`, `func handle(_ transcript: Transcript, from: CaptionLanguage) async`, `func reset()`

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

@Test @MainActor func 같은_문장을_두_번_보내면_한_번만_보정한다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy
    await translator.handle(.final("같은 문장"), from: .korean)
    await translator.handle(.final("같은 문장"), from: .korean)
    #expect(await spy.recorded().count == 1)
}

@Test @MainActor func reset하면_같은_문장을_다시_보정한다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy
    await translator.handle(.final("문장"), from: .korean)
    translator.reset()
    await translator.handle(.final("문장"), from: .korean)
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
    private let debouncer = Debouncer(interval: .milliseconds(220))

    private var lastTranslatedSource = ""
    private var refinedSources: Set<String> = []
    private var recentFinals: [String] = []

    public var refiner: TranslationRefiner?
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
        lastTranslatedSource = ""
        refinedSources.removeAll()
        recentFinals.removeAll()
        Task { await debouncer.cancel() }
    }

    public func handle(_ transcript: Transcript, from source: CaptionLanguage) async {
        guard let target = table.target(for: source) else { return }
        let text = transcript.text
        guard !text.isEmpty else { return }

        if transcript.isFinal {
            // 확정 문장은 기다리지 않는다. 보정 기회도 여기서만 준다.
            await debouncer.cancel()
            await emit(text, from: source, to: target, isFinal: true)
        } else {
            guard text != lastTranslatedSource else { return }
            await debouncer.schedule { [weak self] in
                await self?.emit(text, from: source, to: target, isFinal: false)
            }
        }
    }

    private func emit(_ text: String, from source: CaptionLanguage,
                      to target: CaptionLanguage, isFinal: Bool) async {
        guard let draft = await translate(text, source, target) else { return }
        lastTranslatedSource = text
        onTranslation?(draft, false)
        guard isFinal else { return }

        recentFinals.append(text)
        if recentFinals.count > 3 { recentFinals.removeFirst() }
        await refine(draft, source: text)
    }

    private func refine(_ draft: String, source: String) async {
        guard let refiner, !refinedSources.contains(source) else { return }
        refinedSources.insert(source)
        guard let improved = try? await refiner.refine(
            draft, source: source, context: recentFinals),
              improved != draft
        else { return }
        onTranslation?(improved, true)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `./test.sh`
Expected: 27개 PASS

- [ ] **Step 5: `main.swift` 에서 Google 번역 제거**

기준 커밋 463–489줄 `translate(_:)` 전체와 `scheduleTranslation`, `translateWork`,
`pendingTranslationText`, `lastTranslationStartedAt`, `lastTranslatedSource` 를 삭제하고
`Translator` 로 대체한다.

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

// handle(_:) 의 .transcript 케이스에서:
Task { await translator.handle(transcript, from: pipeline.currentLanguage) }
```

- [ ] **Step 6: Google 흔적이 없는지 확인**

Run: `grep -rn "googleapis\|translate_a\|gtx" Sources/`
Expected: 출력 없음

- [ ] **Step 7: 오프라인 스모크**

1. `./run.sh` 로 실행.
2. Wi-Fi 를 끈다.
3. 한국어로 말한다 → 번역이 나와야 한다.
4. 번역이 안 나오면 언어팩 미설치다. 시스템 설정 → 일반 → 언어 및 지역 → 번역 언어에서
   한국어·영어를 받는다. (Task 8 이 이 안내를 앱 안으로 옮긴다.)
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
    var translated = "Your translation will appear here"
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

`@main` 어트리뷰트를 제거한다. `main.swift` 라는 파일명 자체가 진입점이므로
`@main` 과 함께 쓰면 `'main' attribute cannot be used in a module that contains top-level code` 로 깨진다.
`Package.swift` 에서 `-parse-as-library` 를 주지 않으므로 이 형태가 맞다.

`Sources/LiveBilingualCaptions/AppDelegate.swift` — 나머지 전부. 창 생성은 이렇게 바뀐다:

```swift
private func buildWindow() {
    let size = NSSize(width: 560, height: 188)
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
Expected: 성공

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
- Create: `Sources/CaptionsCore/SystemAudioSource.swift`
- Modify: `Sources/LiveBilingualCaptions/AppDelegate.swift`, `Sources/LiveBilingualCaptions/CaptionOverlay.swift`

**Interfaces:**
- Consumes: `AudioSource`, `AudioSourceError` (Task 4), `AudioSourceKind` (Task 3)
- Produces: `public final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput`

- [ ] **Step 1: `SystemAudioSource` 작성**

`SCStream` 은 `CMSampleBuffer` 를 주므로 `AVAudioPCMBuffer` 로 바꿔야 한다.

`Sources/CaptionsCore/SystemAudioSource.swift`:
```swift
import AVFoundation
import ScreenCaptureKit

/// ScreenCaptureKit 으로 시스템 출력 오디오를 잡는다. 화면 기록 권한이 필요하다.
/// 화면 픽셀은 쓰지 않지만 SCStream 이 오디오만 주는 모드를 제공하지 않으므로
/// 최소 크기 비디오를 함께 받고 버린다.
public final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput {
    private var stream: SCStream?
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var formatContinuation: CheckedContinuation<AVAudioFormat, Error>?
    private var resolvedFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "SystemAudioSource")

    public func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat {
        self.sink = sink

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AudioSourceError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // 자기 소리를 되먹지 않는다
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2                            // 비디오는 안 쓰므로 최소로
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()

        // 첫 오디오 버퍼가 와야 실제 포맷을 알 수 있다.
        return try await withCheckedThrowingContinuation { continuation in
            self.formatContinuation = continuation
        }
    }

    public func stop() {
        let stream = self.stream
        self.stream = nil
        self.sink = nil
        Task { try? await stream?.stopCapture() }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio,
              let description = sampleBuffer.formatDescription,
              let streamBasicDescription = description.audioStreamBasicDescription
        else { return }

        if resolvedFormat == nil {
            var asbd = streamBasicDescription
            guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
            resolvedFormat = format
            formatContinuation?.resume(returning: format)
            formatContinuation = nil
        }
        guard let format = resolvedFormat else { return }

        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        buffer.frameLength = frames

        do {
            try sampleBuffer.copyPCMData(
                fromRange: 0..<sampleBuffer.numSamples,
                into: buffer.mutableAudioBufferList)
            sink?(buffer)
        } catch {
            return
        }
    }
}
```

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
    settings.audioSource = settings.audioSource == .microphone ? .systemAudio : .microphone
    settings.save(to: .standard)
    state.status = "오디오 소스: \(settings.audioSource.displayName)"
    guard running else { return }
    Task {
        await pipeline.stop()
        await pipeline.start(source: makeSource(), language: pipeline.currentLanguage)
    }
}
```

`startListening()` 의 `MicSource()` 를 `makeSource()` 로 바꾼다.

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
    var onChange: (Settings) -> Void

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
                    Text("자동").tag("auto")
                    ForEach(table.languages) { Text($0.displayName).tag($0.id) }
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
            Section("번역 보정") {
                Toggle("Claude 로 확정 문장 다듬기", isOn: $settings.refinementEnabled)
                Text("켜면 확정된 문장만 인터넷으로 전송됩니다. 끄면 모든 처리가 기기 안에서 끝납니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: settings) { _, new in onChange(new) }
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
        settings: Binding(get: { self.settings }, set: { self.settings = $0 }),
        table: .default,
        onChange: { [weak self] new in self?.apply(new) })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Live Bilingual Captions 설정"
    window.contentView = NSHostingView(rootView: view)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow = window
}

private func apply(_ new: Settings) {
    let sourceChanged = new.audioSource != settings.audioSource
    settings = new
    settings.save(to: .standard)
    state.fontSize = new.fontSize
    if sourceChanged, running {
        Task {
            await pipeline.stop()
            await pipeline.start(source: makeSource(), language: pipeline.currentLanguage)
        }
    }
}
```

- [ ] **Step 3: 창 위치 저장 배선**

`applicationDidFinishLaunching` 에서 패널 이동 알림을 구독한다:
```swift
NotificationCenter.default.addObserver(
    forName: NSWindow.didMoveNotification, object: panel, queue: .main
) { [weak self] _ in
    guard let self, let origin = self.panel?.frame.origin else { return }
    self.settings.panelOriginX = origin.x
    self.settings.panelOriginY = origin.y
    self.settings.save(to: .standard)
}
```

- [ ] **Step 4: 자막 유지 시간을 설정에서 읽도록 수정**

기준 커밋 462줄의 하드코딩 `10.0` 을 `settings.captionHoldSeconds` 로 바꾼다.

- [ ] **Step 5: 수동 스모크**

Run: `./run.sh`
1. 메뉴바 "자막" → 설정 → 글자 크기를 바꾼다 → 자막에 **즉시** 반영되는지.
2. 창을 드래그해 옮긴다.
3. 종료 후 재실행 → **창 위치·글자 크기·오디오 소스가 유지되는지.**
4. 인식 언어를 "English" 로 고정 → 한국어를 말해도 영어로 인식하려 하는지.

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
        SecItemDelete(query(account) as CFDictionary)
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

- [ ] **Step 4: 설정 창에 API 키 입력란 추가**

`SettingsView` 의 "번역 보정" 섹션에 추가:
```swift
if settings.refinementEnabled {
    SecureField("Anthropic API 키", text: $apiKey)
        .onSubmit { KeychainStore.save(apiKey, account: KeychainStore.apiKeyAccount) }
    Text("키는 Keychain 에 저장됩니다.")
        .font(.caption).foregroundStyle(.secondary)
}
```
`@State private var apiKey = KeychainStore.read(account: KeychainStore.apiKeyAccount) ?? ""` 를 추가한다.

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
`apply(_:)` 끝과 `applicationDidFinishLaunching` 에서 호출한다.
`refinerModel` 은 Step 0 에서 확인한 모델 ID 상수다.

- [ ] **Step 6: 수동 스모크**

1. 설정에서 보정을 **끈 채로** 실행 → 자막·번역이 정상 동작하는지. **이게 기본 경로다.**
2. Wi-Fi 를 끈 상태로 보정을 켠다 → 보정만 실패하고 **자막은 계속 나와야 한다.**
3. 유효한 키를 넣고 보정을 켠다 → 확정 문장에서 번역이 한 번 교체되며 크로스페이드되는지.
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

누락 없음.

**2. 플레이스홀더** — "TBD"·"적절히 처리"·"위 내용에 대한 테스트" 없음. 모든 코드 단계에 실제 코드가 있다.

**3. 테스트 누적 개수** — 각 태스크의 기대 개수가 맞는지 대조했다.

| 태스크 | 추가 | 누적 |
|---|---|---|
| Task 1 스모크 | 1 | 1 |
| Task 2 언어 테이블 | 7 | 8 |
| Task 3 문자열·설정·디바운서 | 12 | 20 |
| Task 5 Transcript | 2 | 22 |
| Task 6 Translator | 5 | 27 |
| Task 10 Keychain | 1 | 28 |

**4. 타입 일관성** — 태스크 간 사용 이름을 대조했다.
`CaptionLanguage.id`(Task 2) → Task 3 `LanguageMode.fixed(String)`, Task 9 Picker tag 에서 동일하게 사용.
`AudioSource.start` 가 `AVAudioFormat` 을 반환(Task 4) → Task 5 `prepareToAnalyze(in:)`, Task 8 `SystemAudioSource` 에서 동일.
`Transcript`(Task 5) → Task 6 `Translator.handle` 이 동일 타입 수신.
`TranslationRefiner.refine(_:source:context:)`(Task 6) → Task 10 `ClaudeRefiner` 가 동일 시그니처 구현.
`Settings.refinementEnabled`(Task 3) → Task 9 Toggle, Task 10 `updateRefiner()` 에서 동일.
불일치 없음.

**5. 검토 중 고친 결함 1건** — Task 6 의 초안은 `Translator` 가 `TranslationSession` 을
직접 만들어 쓰게 되어 있었다. 그러면 테스트가 **이 머신의 언어팩 설치 상태에 따라
통과하기도 실패하기도 한다.** 번역을 `TranslateFunction` 으로 주입 가능하게 바꾸고
테스트는 가짜를 넣도록 고쳤다. 앱 경로는 기본값 `Translator.onDevice` 를 그대로 쓴다.
