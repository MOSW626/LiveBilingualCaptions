import Foundation
import Observation

/// 화면에 남아 있는 발화 하나. 원문과 번역이 같은 ID 아래 붙어 있어서
/// 늦게 도착한 번역도 자기 줄을 찾아갈 수 있다.
public struct CaptionEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var original: String
    public var translated: String
    public var isFinal: Bool
    public var sourceLanguageID: String

    public init(id: UUID, original: String, translated: String,
                isFinal: Bool, sourceLanguageID: String) {
        self.id = id
        self.original = original
        self.translated = translated
        self.isFinal = isFinal
        self.sourceLanguageID = sourceLanguageID
    }
}

/// 자막 화면의 상태 전부.
///
/// 자막은 **한 줄짜리 현재 상태가 아니라 최근 발화의 목록**이다(스펙 §6.6).
/// 기준 커밋은 새 발화가 감지되면 이전 자막을 즉시 지워서 읽을 시간이 없었다.
///
/// UI 타깃이 아니라 CaptionsCore 에 둔다: 목록 규칙(갱신 vs 추가, 번역 라우팅, 트리밍)이
/// 이 앱에서 가장 틀리기 쉬운 순수 로직인데, 테스트 타깃은 CaptionsCore 만 의존한다.
/// 실행 타깃은 최상위 코드가 있는 main.swift 라 테스트 번들에 링크할 수 없다.
@Observable
@MainActor
public final class CaptionState {
    /// 최근 발화들. 마지막 원소가 가장 최신이며 진행 중일 수 있다.
    public var entries: [CaptionEntry] = []
    public var status = "준비 중…"
    public var fontSize: Double = 20
    public var historyCount = Settings.defaultCaptionHistoryCount
    public var isRunning = false
    /// 시작/정지 버튼 제목. "정지 중…", "다시 시작" 같은 중간 상태까지 그대로 보여준다.
    public var toggleTitle = "시작"
    public var canToggle = true
    /// 언어 버튼 제목. 자동 모드에서는 언어 이름이 아니라 "자동 (실험)"이 붙는다.
    public var languageTitle = CaptionLanguage.korean.displayName
    public var sourceLanguage: CaptionLanguage = .korean
    public var targetLanguage: CaptionLanguage = .english

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// 같은 발화 ID면 기존 항목을 갱신하고, 새 ID면 항목을 추가한다.
    /// 발화마다 화면을 비우지 않는다 — 연속 발화 중에는 이전 자막이 남아야 한다.
    public func upsert(id: UUID, original: String, isFinal: Bool, sourceLanguageID: String) {
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].original = original
            entries[i].isFinal = isFinal
        } else {
            entries.append(CaptionEntry(id: id, original: original, translated: "",
                                        isFinal: isFinal, sourceLanguageID: sourceLanguageID))
        }
        trim()
    }

    /// 늦게 도착한 번역은 해당 발화에만 반영한다. 다른 항목을 건드리지 않고,
    /// 이미 밀려난 발화의 번역이면 조용히 버린다.
    public func setTranslation(_ text: String, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].translated = text
    }

    /// 침묵이 이어졌을 때만 부른다. 발화가 바뀌었다는 이유로는 부르지 않는다.
    public func clear() { entries.removeAll() }

    private func trim() {
        let limit = max(1, historyCount)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }
}
