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
    private struct SubmissionKey: Equatable {
        let text: String
        let sourceID: String
        let targetID: String
        let isFinal: Bool
    }

    /// 자막 한 줄의 진행 상태. **줄마다 따로** 들고 있는 게 핵심이다.
    ///
    /// 예전에는 `pending`/`generation`/`lastSubmission` 이 번역기 전체에 하나씩이었다.
    /// 자막이 한 줄이던 시절엔 맞았지만, 목록 UI에서 옛 발화의 뒤늦은 final을 다시
    /// 제출하게 되자(`CaptionState.apply`) 그 제출이 **방금 사용자가 말한 줄**의 진행 중
    /// 번역을 취소해버렸다. 말을 마치고 잠시 쉬면 그 줄은 영영 번역 없이 남는다 —
    /// 화자가 읽으라고 멈추는 바로 그 순간에 터지는 흔한 경로다.
    private struct Line {
        let captionID: UUID
        var ticket: UInt64 = 0
        var pending: Task<Void, Never>?
        var lastSubmission: SubmissionKey?
    }

    /// 삽입 순서 배열. 조회와 퇴출을 같이 하고 상한이 작아 선형 탐색으로 충분하다.
    private var lines: [Line] = []
    /// 화면에 남을 수 있는 최대 줄 수(`Settings` 가 1...10으로 clamp 한다) + 여유.
    /// 긴 세션에서 무한히 자라지 않게 하고, 밀려나는 줄의 작업은 그때 취소한다.
    static let lineLimit = Settings.captionHistoryCountRange.upperBound + 4
    private var refinedIDs: [UUID] = []

    /// 원문 한 문장과 그 문장에 실제로 채택된(화면에 남은) 번역의 쌍.
    /// 보정기가 용어·톤을 앞선 문장들과 맞출 수 있도록 문맥으로 건넨다.
    private struct ContextPair {
        let captionID: UUID
        let sourceLangID: String
        let source: String
        var translated: String
    }
    /// 문맥으로 실제 사용하는 최근 문장 수. 너무 적으면 문맥이 없는 것과 같고,
    /// 너무 크면 프롬프트가 비대해져 지연이 늘고 오래된 용어가 섞여 들어온다.
    static let contextWindowSize = 8
    /// 원시 보관량은 창보다 넉넉히 둔다 — 세션 중 원문 언어가 바뀌어도(드묾) 필터링 후
    /// 같은 언어끼리 최근 8개를 채울 여유를 남기기 위해서다.
    private static let contextHistoryCapacity = contextWindowSize * 2
    private var contextHistory: [ContextPair] = []

    public var preferredTargetID: String?
    public var refiner: TranslationRefiner? {
        didSet { reset() } // 끄기·키 교체 시 이미 진행 중인 보정 응답도 무효화
    }
    /// (번역문, 보정됨, 발화 ID) — 보정됨이 true 면 크로스페이드로 교체하라는 뜻.
    /// 발화 ID 가 있어야 늦게 도착한 번역을 자막 목록의 **해당 줄에만** 반영할 수 있다.
    public var onTranslation: (@MainActor (String, Bool, UUID) -> Void)?

    public init(table: LanguageTable, translate: @escaping TranslateFunction = Translator.onDevice) {
        self.table = table
        self.translate = translate
    }

    /// 실제 온디바이스 번역. 언어팩이 없으면 nil 을 돌려주고,
    /// 다운로드 프롬프트는 UI 의 .translationTask 가 맡는다.
    ///
    /// `.lowLatency` 를 **명시적으로** 요구한다. 기본 전략은 애플이 고르고, 고르는 기준에
    /// 서버 왕복이 들어갈 수 있다 — 자막은 문장마다 즉시 나와야 하고 오프라인에서도
    /// 돌아야 하므로 둘 다 받아들일 수 없다. 번역 품질은 선택적 LLM 보정이 맡는다.
    /// (`Strategy` 는 macOS 26.4 부터다. 그 이전에서는 기본 전략으로 돌아간다.)
    public static let onDevice: TranslateFunction = { text, source, target in
        guard await packStatus(from: source, to: target) == .installed else { return nil }
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(
                installedSource: source.locale.language, target: target.locale.language,
                preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(
                installedSource: source.locale.language, target: target.locale.language)
        }
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

    /// 전부 취소하고 줄별 상태를 통째로 버린다. 언어쌍 변경·보정기 교체처럼
    /// 화면의 모든 번역이 한꺼번에 무의미해지는 경우에만 부른다.
    public func reset() {
        for line in lines { line.pending?.cancel() }
        lines.removeAll()
        refinedIDs.removeAll()
        contextHistory.removeAll()
    }

    /// 해당 줄의 진행 중 작업만 끊는다.
    private func cancelLine(_ captionID: UUID) {
        guard let i = lines.firstIndex(where: { $0.captionID == captionID }) else { return }
        lines[i].pending?.cancel()
        lines[i].pending = nil
        lines[i].lastSubmission = nil
        lines[i].ticket &+= 1
    }

    /// 줄의 자리를 찾고, 없으면 만든다. 상한을 넘으면 가장 오래된 줄부터 퇴출하고
    /// 그 줄의 진행 중 작업은 취소한다 — 화면에 없는 줄의 번역은 갈 데가 없다.
    private func lineIndex(for captionID: UUID) -> Int {
        if let i = lines.firstIndex(where: { $0.captionID == captionID }) { return i }
        lines.append(Line(captionID: captionID))
        if lines.count > Self.lineLimit {
            let excess = lines.count - Self.lineLimit
            for evicted in lines.prefix(excess) { evicted.pending?.cancel() }
            lines.removeFirst(excess)
        }
        return lines.count - 1
    }

    /// UI 이벤트에서 직접 호출한다. Task로 감싸기 전에 이전 요청을 무효화해야 한다.
    /// captionID는 파이프라인이 발급한 발화 ID. 같은 발화의 partial/final에 동일 ID를 쓴다.
    @discardableResult
    public func submit(_ transcript: Transcript, from source: CaptionLanguage,
                       captionID: UUID) -> Task<Void, Never>? {
        guard let target = table.target(for: source, preferredID: preferredTargetID),
              !transcript.text.isEmpty else {
            // 번역할 게 없다. 이 줄만 끊는다 — 여기서 reset()을 부르면 다른 줄의
            // 진행 중 번역까지 날아가고, 그게 바로 이 구조가 고친 결함이다.
            cancelLine(captionID)
            return nil
        }
        let key = SubmissionKey(text: transcript.text, sourceID: source.id,
                                targetID: target.id, isFinal: transcript.isFinal)
        let index = lineIndex(for: captionID)
        // 중복 final로 진행 중 보정까지 취소하지 않는다. 판단은 **그 줄 안에서만** 한다 —
        // 전역으로 보면 A줄 제출이 똑같이 생긴 B줄 제출을 억눌러버린다.
        if lines[index].lastSubmission == key { return lines[index].pending }
        lines[index].lastSubmission = key
        lines[index].ticket &+= 1
        let ticket = lines[index].ticket
        // 취소도 그 줄에만. 다른 줄의 진행 중 번역은 건드리지 않는다.
        lines[index].pending?.cancel()
        lines[index].pending = nil
        let text = transcript.text
        let task = Task { [weak self] in
            guard let self else { return }
            if !transcript.isFinal {
                do { try await Task.sleep(for: .milliseconds(220)) }
                catch { return }
            }
            guard self.isCurrent(ticket, for: captionID) else { return }
            await self.emit(text, from: source, to: target, isFinal: transcript.isFinal,
                            captionID: captionID, ticket: ticket)
        }
        lines[index].pending = task
        return task
    }

    /// 테스트·직렬 호출용. 앱 이벤트 경로는 동기 submit을 쓴다.
    public func handle(_ transcript: Transcript, from source: CaptionLanguage,
                       captionID: UUID = UUID()) async {
        let task = submit(transcript, from: source, captionID: captionID)
        await task?.value
    }

    /// 응답이 아직 유효한가 — **자기 줄의** 최신 제출인지로만 판단한다.
    /// 줄이 퇴출됐거나 reset 됐으면 자리가 없으므로 자연히 무효다.
    private func isCurrent(_ ticket: UInt64, for captionID: UUID) -> Bool {
        guard let line = lines.first(where: { $0.captionID == captionID }) else { return false }
        return line.ticket == ticket && !Task.isCancelled
    }

    private func emit(_ text: String, from source: CaptionLanguage,
                      to target: CaptionLanguage, isFinal: Bool,
                      captionID: UUID, ticket: UInt64) async {
        guard let draft = await translate(text, source, target),
              isCurrent(ticket, for: captionID) else { return }
        onTranslation?(draft, false, captionID)
        guard isCurrent(ticket, for: captionID), isFinal, !refinedIDs.contains(captionID) else { return }
        // 현재 문장을 '직전 문장들'에 중복해서 넣지 않는다 — 필터·창은 여기서 한 번에.
        let context = contextHistory
            .filter { $0.sourceLangID == source.id }
            .suffix(Self.contextWindowSize)
            .map { "원문: \($0.source)\n번역: \($0.translated)" }
        contextHistory.append(ContextPair(captionID: captionID, sourceLangID: source.id,
                                          source: text, translated: draft))
        if contextHistory.count > Self.contextHistoryCapacity { contextHistory.removeFirst() }
        guard let refiner else { return }
        refinedIDs.append(captionID)
        if refinedIDs.count > 256 { refinedIDs.removeFirst() }
        guard let improved = try? await refiner.refine(
            draft, source: text, context: context),
              isCurrent(ticket, for: captionID), !improved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              improved != draft
        else { return }
        // 채택된 번역으로 갱신해둬야 다음 문장의 문맥이 다듬어진 쪽을 본다.
        if let i = contextHistory.firstIndex(where: { $0.captionID == captionID }) {
            contextHistory[i].translated = improved
        }
        onTranslation?(improved, true, captionID)
    }
}
