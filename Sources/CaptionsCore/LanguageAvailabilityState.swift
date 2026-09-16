import Foundation
import Observation

/// 설정 창의 언어 선택지 중 어떤 것이 비활성/다운로드 필요인지. 조회는 **방향별**이다 —
/// 같은 언어쌍이라도 ko→en과 en→ko의 팩 상태가 다를 수 있다.
///
/// 조회는 비동기라 응답이 요청 순서대로 오지 않는다. 세대 카운터로 구버전 응답이 새
/// 선택(예: 원문을 바꾼 직후 도착한 옛 조회)을 덮어쓰지 못하게 막는다.
@Observable
@MainActor
public final class LanguageAvailabilityState {
    public var disabledLanguageIDs: Set<String> = []
    public var disabledTargetIDs: Set<String> = []
    /// "sourceID→targetID" 형태. `.supported`(다운로드 필요)인 방향만 담는다.
    public var downloadHintPairIDs: Set<String> = []

    private var generation = 0

    public init() {}

    /// 고정 원문 선택지 각각(그 언어를 원문으로 뒀을 때 테이블이 고르는 기본 대상과의 방향)과,
    /// 현재 원문 기준 번역 대상 후보 각각을 조회한다. 도중에 `refresh`가 다시 불리면 이전
    /// 조회의 결과는 버려진다.
    public func refresh(
        source: CaptionLanguage, table: LanguageTable, preferredTargetID: String?,
        packStatus: @escaping @Sendable (CaptionLanguage, CaptionLanguage) async -> PackStatus
    ) async {
        generation += 1
        let myGeneration = generation

        var disabledSources: Set<String> = []
        var disabledTargets: Set<String> = []
        var hints: Set<String> = []

        for candidate in table.languages {
            guard let target = table.target(for: candidate, preferredID: preferredTargetID) else { continue }
            switch await packStatus(candidate, target) {
            case .unsupported: disabledSources.insert(candidate.id)
            case .needsDownload: hints.insert("\(candidate.id)→\(target.id)")
            case .installed: break
            }
        }

        for target in table.languages where target != source {
            switch await packStatus(source, target) {
            case .unsupported: disabledTargets.insert(target.id)
            case .needsDownload: hints.insert("\(source.id)→\(target.id)")
            case .installed: break
            }
        }

        guard myGeneration == generation else { return } // 더 새 조회가 이미 진행 중이거나 끝났다
        disabledLanguageIDs = disabledSources
        disabledTargetIDs = disabledTargets
        downloadHintPairIDs = hints
    }
}
