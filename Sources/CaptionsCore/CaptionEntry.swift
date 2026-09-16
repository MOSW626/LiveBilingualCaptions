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

/// `CaptionState.apply`가 돌려주는 줄 하나의 결과. 호출자는 이 `id`와 `transcript`로
/// `Translator.submit`을 부르면 된다 — 세그멘테이션이 쪼갠 문장마다 자기 번역을 받는다
/// (스펙 §1, §4).
public struct CaptionRowUpdate: Sendable, Equatable {
    public let id: UUID
    public let transcript: Transcript

    public init(id: UUID, transcript: Transcript) {
        self.id = id
        self.transcript = transcript
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
    /// `CaptionSegmenter`의 안전망 상한. 패널 폭·글자 크기가 바뀔 때만(호출자가)
    /// `CaptionSegmenter.recommendedCap`으로 다시 계산해 여기 채운다 — 문장마다
    /// 재계산하지 않는다(그 비용은 `CaptionSegmenter.recommendedCap`의 문서 참고).
    public var segmentCap = CaptionSegmenter.defaultCap
    public var isRunning = false
    /// 시작/정지 버튼 제목. "정지 중…", "다시 시작" 같은 중간 상태까지 그대로 보여준다.
    public var toggleTitle = "시작"
    public var canToggle = true
    /// 언어 버튼 제목. 자동 모드에서는 언어 이름이 아니라 "자동"이 붙는다.
    public var languageTitle = CaptionLanguage.korean.displayName
    public var sourceLanguage: CaptionLanguage = .korean
    public var targetLanguage: CaptionLanguage = .english
    /// 오디오 소스 버튼 제목. "마이크" / "시스템 오디오".
    public var audioSourceName = AudioSourceKind.microphone.displayName

    @ObservationIgnored private var latest = LatestCaption()
    /// (`runID`, `utteranceID`, `segmentIndex`) 세 쌍 → 그 문장 줄이 받은 UUID.
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
    ///
    /// `segmentIndex`가 더 있는 이유: 발화 하나(`utteranceID` 하나)가 `CaptionSegmenter`를
    /// 거치며 문장 여러 개로 쪼개질 수 있다 — 문장마다 자기 줄, 자기 번역이 필요하다
    /// (스펙 §1, §4). 인덱스는 0부터, 왼쪽에서 오른쪽 문장 순서다. 세그멘터가 상태 없이
    /// 매번 전체 텍스트를 처음부터 다시 훑으므로 같은 발화의 revision마다 같은 인덱스가
    /// 같은 문장을 가리킨다 — 그래서 이 인덱스를 장부 키에 그대로 써도 안전하다.
    @ObservationIgnored private var captionIDs: [(runID: Int, utteranceID: Int, segmentIndex: Int, captionID: UUID)] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// 전사 이벤트 하나를 목록에 반영하고, 번역을 걸어야 할 줄들을 돌려준다.
    ///
    /// **이 함수는 어떤 경우에도 목록을 비우지 않는다.** 새 발화는 줄을 추가하고,
    /// 같은 발화의 partial→final 갱신은 제자리를 덮고, 옛 발화의 뒤늦은 갱신은
    /// 자기 줄을 찾아간다. 화면을 비우는 건 침묵과 "지우기"뿐이다(`clear()`).
    ///
    /// 이벤트 하나가 줄 하나라고는 더 이상 보장하지 않는다 — `CaptionSegmenter`가 이
    /// 이벤트의 누적 텍스트를 문장(또는 안전망이 끊은 조각) 단위로 쪼개고, 여기서는
    /// 조각마다 자기 UUID를 배정해 문장마다 독립된 번역을 받을 수 있게 한다(스펙 §1,
    /// §4). 짧고 문장부호 없는 평범한 partial은 조각이 하나뿐이라 예전과 동일하게
    /// 동작한다. 빈 배열은 "반영할 줄이 없다"는 뜻이다 — 이미 밀려난 옛 발화의 갱신이
    /// 그렇다. 그 경우 번역도 걸지 않는다. 보여줄 데가 없는 번역이라서다.
    ///
    /// `runID`는 이 이벤트를 만든 파이프라인 실행(Run)의 식별자다(`PipelineEvent.runID`).
    /// `TranscriptEvent` 자체에는 실려 있지 않으므로 호출자가 감싸는 `PipelineEvent`에서
    /// 꺼내 넘긴다. 기본값 0은 실제 파이프라인이 절대 쓰지 않는 값이라(첫 실행 ID는 1)
    /// runID를 신경 쓰지 않는 기존 테스트가 한 실행 안에 있는 것처럼 동작한다.
    @discardableResult
    public func apply(_ event: TranscriptEvent, runID: Int = 0) -> [CaptionRowUpdate] {
        let update = latest.apply(event)
        var results: [CaptionRowUpdate] = []
        let segments = CaptionSegmenter.segment(update.text, isFinal: event.isFinal, cap: segmentCap)
        for (index, segment) in segments.enumerated() {
            let id: UUID
            if update.isOutdated {
                // 옛 줄이 아직 화면에 있을 때만 갱신한다. 밀려난 발화를 맨 아래에 되살리지 않는다.
                guard let known = captionIDs.first(where: {
                          $0.runID == runID && $0.utteranceID == event.utteranceID && $0.segmentIndex == index
                      })?.captionID,
                      entries.contains(where: { $0.id == known })
                else { continue }
                id = known
            } else {
                id = captionID(for: event.utteranceID, segmentIndex: index, runID: runID)
            }
            upsert(id: id, original: segment.text, isFinal: segment.isComplete,
                   sourceLanguageID: event.sourceLanguage.id)
            let transcript: Transcript = segment.isComplete ? .final(segment.text) : .partial(segment.text)
            results.append(CaptionRowUpdate(id: id, transcript: transcript))
        }
        return results
    }

    private func captionID(for utteranceID: Int, segmentIndex: Int, runID: Int) -> UUID {
        if let known = captionIDs.first(where: {
            $0.runID == runID && $0.utteranceID == utteranceID && $0.segmentIndex == segmentIndex
        })?.captionID {
            return known
        }
        let fresh = UUID()
        captionIDs.append((runID, utteranceID, segmentIndex, fresh))
        // 화면에 남는 줄 + 여유. 늦게 도착하는 갱신을 받아줄 만큼만 기억한다. 발화 하나가
        // 여러 문장으로 쪼개질 수 있으므로 예전 한 줄짜리 여유(+4)보다 넉넉히 곱해 둔다.
        let bound = (max(1, historyCount) + 4) * 4
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
