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
    /// (번역문, 보정됨, 발화 ID) — 보정됨이 true 면 크로스페이드로 교체하라는 뜻.
    /// 발화 ID 가 있어야 늦게 도착한 번역을 자막 목록의 **해당 줄에만** 반영할 수 있다.
    public var onTranslation: (@MainActor (String, Bool, UUID) -> Void)?

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
        onTranslation?(draft, false, captionID)
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
        onTranslation?(improved, true, captionID)
    }
}
