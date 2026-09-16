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
    /// 오디오 소스 버튼 제목. "마이크" / "시스템 오디오".
    public var audioSourceName = AudioSourceKind.microphone.displayName

    @ObservationIgnored private var latest = LatestCaption()
    /// 파이프라인의 (`runID`, `utteranceID`) 쌍 → 그 발화가 받은 줄의 UUID.
    ///
    /// 단일 슬롯으로는 안 된다: 옛 구간의 뒤늦은 갱신에 새 UUID를 발급하면 옛 발화가
    /// 목록 맨 아래에 중복으로 끼어들고, 진행 중이던 발화까지 두 줄로 쪼개진다.
    /// 삽입 순서 배열 하나로 조회와 퇴출을 같이 한다 — 원소는 화면 줄 수 + 여유가 상한이라
    /// 선형 탐색으로 충분하다.
    ///
    /// 키가 `utteranceID` 단독이 아니라 `runID`와의 쌍인 이유: `utteranceID`는 파이프라인
    /// 실행(Run) 하나 안에서만 유일하다. 언어 hot swap이 실패해 조용히 새 Run으로
    /// 재시작되면(AppDelegate는 이를 미리 알 수 없다) 새 Run의 `utteranceID`도 1부터
    /// 다시 시작한다 — 그때 장부가 남아 있으면(resetLedger를 건너뛴 경우) 옛 Run이 남긴
    /// 같은 번호가 새 발화를 옛 줄로 잘못 끌어들인다. `runID`까지 같이 봐야 옛 Run이
    /// 남긴 항목이 새 Run의 번호와 절대 부딪히지 않는다.
    @ObservationIgnored private var captionIDs: [(runID: Int, utteranceID: Int, captionID: UUID)] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// 전사 이벤트 하나를 목록에 반영하고, 번역을 걸 발화 ID를 돌려준다.
    ///
    /// **이 함수는 어떤 경우에도 목록을 비우지 않는다.** 새 발화는 줄을 추가하고,
    /// 같은 발화의 partial→final 갱신은 제자리를 덮고, 옛 발화의 뒤늦은 갱신은
    /// 자기 줄을 찾아간다. 화면을 비우는 건 침묵과 "지우기"뿐이다(`clear()`).
    ///
    /// nil은 "반영할 줄이 없다"는 뜻이다 — 이미 밀려난 옛 발화의 갱신이 그렇다.
    /// 그 경우 번역도 걸지 않는다. 보여줄 데가 없는 번역이라서다.
    ///
    /// `runID`는 이 이벤트를 만든 파이프라인 실행(Run)의 식별자다(`PipelineEvent.runID`).
    /// `TranscriptEvent` 자체에는 실려 있지 않으므로 호출자가 감싸는 `PipelineEvent`에서
    /// 꺼내 넘긴다. 기본값 0은 실제 파이프라인이 절대 쓰지 않는 값이라(첫 실행 ID는 1)
    /// runID를 신경 쓰지 않는 기존 테스트가 한 실행 안에 있는 것처럼 동작한다.
    @discardableResult
    public func apply(_ event: TranscriptEvent, runID: Int = 0) -> UUID? {
        let update = latest.apply(event)
        let id: UUID
        if update.isOutdated {
            // 옛 줄이 아직 화면에 있을 때만 갱신한다. 밀려난 발화를 맨 아래에 되살리지 않는다.
            guard let known = captionIDs.first(where: { $0.runID == runID && $0.utteranceID == event.utteranceID })?.captionID,
                  entries.contains(where: { $0.id == known })
            else { return nil }
            id = known
        } else {
            id = captionID(for: event.utteranceID, runID: runID)
        }
        upsert(id: id, original: CaptionText.tail(update.text),
               isFinal: event.isFinal, sourceLanguageID: event.sourceLanguage.id)
        return id
    }

    private func captionID(for utteranceID: Int, runID: Int) -> UUID {
        if let known = captionIDs.first(where: { $0.runID == runID && $0.utteranceID == utteranceID })?.captionID {
            return known
        }
        let fresh = UUID()
        captionIDs.append((runID, utteranceID, fresh))
        // 화면에 남는 줄 + 여유. 늦게 도착하는 갱신을 받아줄 만큼만 기억한다.
        let bound = max(1, historyCount) + 4
        if captionIDs.count > bound { captionIDs.removeFirst(captionIDs.count - bound) }
        return fresh
    }

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

    /// 화면을 비운다. **침묵이 이어졌을 때와 "지우기" 버튼에서만** 부른다.
    /// 발화가 바뀌었다는 이유로는 절대 부르지 않는다.
    public func clear() {
        entries.removeAll()
        resetLedger()
    }

    /// 화면은 그대로 두고 발화 ID 장부만 비운다. 정지·언어 전환처럼 다음 발화가 새 줄에서
    /// 시작해야 할 때 쓴다 — 읽고 있던 자막을 뺏지 않는다.
    public func resetLedger() {
        latest.reset()
        captionIDs.removeAll()
    }

    private func trim() {
        let limit = max(1, historyCount)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }
}
