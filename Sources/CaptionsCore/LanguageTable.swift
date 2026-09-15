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
