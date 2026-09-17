import Foundation

/// 세션 안에서 반복되거나 두드러지는 용어 후보를 뽑아 `SpeechAnalyzer.setContext`에 먹일
/// 힌트 목록을 만든다. 순수 상태 기계다 — Speech 프레임워크를 모르고, 오디오 스레드와도
/// 무관하다(파이프라인이 consume 태스크에서 확정된 전사마다 먹이고, 결과를 analyzer에 넘긴다).
/// 이렇게 하면 세션이 길어질수록 "맥락"(반복되는 이름·용어)을 점점 더 잘 알아듣게 된다 —
/// 이 세션 안에서만, 무료로, 기기 안에서.
///
/// **언어별로 분리**: 자동 모드는 두 언어를 동시에 듣는다. 영어 스택에 한국어 인명이
/// 섞여 들어가 봐야 도움이 안 되므로 언어마다 완전히 다른 용어 뭉치를 유지한다.
///
/// **경계(ponytail)**: 둘 다 형태소 분석 없는 휴리스틱이다 — 영어는 정규식 수준(대문자로
/// 시작하는 단어), 한국어는 공백으로 나눈 토큰을 음절 수만 센다. 조사가 안 떨어진 토큰
/// ("애플이", "구글은")은 매번 다른 문자열로 잡혀 반복 카운트가 갈라질 수 있다 — 서드파티
/// 형태소 분석기 없이 고치기 어렵고, 이 규모의 앱에 그 정확도가 꼭 필요한지도 불확실하다.
public struct ContextHintExtractor: Sendable {
    /// `SpeechAnalyzer.setContext` 한 번에 넘기는 상한(스펙).
    public static let maxTerms = 40

    private struct TermStat {
        var count = 0
        var lastOrder = 0
    }

    private var statsByLanguage: [String: [String: TermStat]] = [:]
    private var order = 0

    public init() {}

    /// 확정된 전사문 하나를 먹인다. 이 언어에 **새 용어**가 추가됐으면 true를 돌려준다 —
    /// 호출자가 "지금 바로 밀어야 하나"를 이 신호로 판단한다(N개마다 미는 것과는 별개로).
    @discardableResult
    public mutating func ingestFinal(_ text: String, language: CaptionLanguage) -> Bool {
        order += 1
        let candidates = Self.candidates(in: text, language: language)
        guard !candidates.isEmpty else { return false }

        var stats = statsByLanguage[language.id] ?? [:]
        var addedNewTerm = false
        for term in candidates {
            if stats[term] == nil { addedNewTerm = true }
            var stat = stats[term] ?? TermStat()
            stat.count += 1
            stat.lastOrder = order
            stats[term] = stat
        }
        statsByLanguage[language.id] = stats
        return addedNewTerm
    }

    /// 지금 이 언어에 대해 analyzer에 넘길 힌트 목록. 최신·빈도 순으로 정렬해 ≤ `maxTerms`개만.
    public func terms(for language: CaptionLanguage) -> [String] {
        guard let stats = statsByLanguage[language.id] else { return [] }
        return stats
            .filter { term, stat in Self.qualifies(term, count: stat.count, language: language) }
            .sorted { a, b in
                a.value.lastOrder != b.value.lastOrder
                    ? a.value.lastOrder > b.value.lastOrder
                    : a.value.count > b.value.count
            }
            .prefix(Self.maxTerms)
            .map(\.key)
    }

    /// 실행 재시작 시 부른다(파이프라인은 실행마다 새 `Run`을 만들어 자연히 이렇게 되지만,
    /// 명시적으로도 가능하게 남겨 둔다). 언어를 건 hot swap에서는 부르지 않는다 — 살아남는
    /// 언어의 누적 용어는 그대로 유지해야 한다(스펙).
    public mutating func reset() {
        statsByLanguage = [:]
        order = 0
    }

    // MARK: - 채택 규칙

    private static func qualifies(_ term: String, count: Int, language: CaptionLanguage) -> Bool {
        guard language.id == CaptionLanguage.korean.id else { return true } // 영어: 후보 = 채택.
        return count >= 2 || term.count >= 4 // 한국어: 반복(≥2회) 또는 긴 단어(≥4음절).
    }

    // MARK: - 언어별 후보 추출

    private static let punctuationToStrip = CharacterSet.punctuationCharacters.union(.symbols)

    private static func candidates(in text: String, language: CaptionLanguage) -> [String] {
        let tokens = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: punctuationToStrip) }
            .filter { !$0.isEmpty }

        return language.id == CaptionLanguage.korean.id
            ? tokens.compactMap(koreanCandidate)
            : tokens.compactMap(englishCandidate)
    }

    /// 영어: 대문자로 시작하는 순수 알파벳 단어(고유명사 생김새). 문장 첫머리에 흔한
    /// 지시어·대명사·접속사는 불용어로 뺀다.
    private static func englishCandidate(_ token: String) -> String? {
        guard token.count >= 2, token.allSatisfy(\.isLetter) else { return nil }
        guard let first = token.first, first.isUppercase else { return nil }
        guard !englishStopwords.contains(token.lowercased()) else { return nil }
        return token
    }

    /// 한국어: 한글 음절로만 이루어진 2음절 이상 토큰. 반복/길이 채택 여부는 `qualifies`가 가른다.
    private static func koreanCandidate(_ token: String) -> String? {
        guard token.count >= 2 else { return nil }
        guard token.unicodeScalars.allSatisfy({ (0xAC00...0xD7A3).contains($0.value) }) else { return nil }
        guard !koreanStopwords.contains(token) else { return nil }
        return token
    }

    private static let englishStopwords: Set<String> = [
        "the", "this", "that", "these", "those", "a", "an", "i", "it", "we", "you",
        "he", "she", "they", "my", "our", "your", "his", "her", "its", "there",
        "here", "so", "but", "and", "or", "if", "when", "what", "where", "who",
        "why", "how", "yes", "no", "okay", "ok", "well", "now", "then",
    ]

    private static let koreanStopwords: Set<String> = [
        "그리고", "그런데", "하지만", "그래서", "그러면", "그러니까", "그냥", "진짜",
        "정말", "이제", "저기", "여기", "거기", "오늘", "지금", "우리", "저는", "나는",
        "그게", "이게", "저게", "근데", "아니", "음", "저기요", "약간", "일단",
    ]
}
