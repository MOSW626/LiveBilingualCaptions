import Foundation

/// 발화 하나의 누적 전체 텍스트를 문장 단위 줄로 나눈다.
///
/// **문제**: 전사기는 한국어에 문장부호를 붙여 주지만(스펙에서 측정한 사실), 한
/// 발화의 확정(final)을 문장마다 쪼개 주지는 않는다 — 세 문장을 말해도 final은 하나만
/// 온다(영어는 문장마다 final이 따로 온다). 그 final 하나를 그대로 한 자막 줄에
/// 얹으면 문장 세 개가 뭉친 거대한 한 줄이 되고, 그걸 잘라내는 두 겹의 트렁케이션
/// (`CaptionText.tail`의 머리 자르기, `CaptionOverlay`의 `.lineLimit(2)` 꼬리 자르기)이
/// 문장 가운데를 씹어먹는다. 그래서 문장 경계는 우리 쪽에서 직접 찾아야 한다.
///
/// **상태가 없다**: 매번 발화의 누적 전체 텍스트(델타가 아니라 지금까지 나온 전부)를
/// 처음부터 다시 훑는다. 파이프라인 전체가 이미 "전사문은 앞이 안 바뀌고 뒤로만
/// 자란다"는 전제 위에 서 있다(`LatestCaption`도 그렇다). 그 전제 아래, 왼쪽에서
/// 오른쪽으로 그리디하게 훑는 이 알고리즘은 텍스트가 늘어나도 이미 정해 놓은 경계를
/// 그대로 재현한다 — 그래서 `CaptionState`가 같은 발화의 revision마다 다시 불러도
/// 이전에 확정한 문장의 개수·내용이 흔들리지 않고, 세그먼트 인덱스를 자막 줄 ID에
/// 안정적으로 대응시킬 수 있다.
public enum CaptionSegmenter {
    /// 문장 하나(또는 안전망이 끊은 조각 하나)에 대응하는 결과 한 줄.
    public struct Segment: Sendable, Equatable {
        public let text: String
        /// true면 이 줄은 더 이상 자라지 않는다 — 문장부호로 끝났거나, 안전망이
        /// 강제로 끊었거나, 발화 자체가 끝났다(파이프라인이 확정을 보냈다).
        public let isComplete: Bool

        public init(text: String, isComplete: Bool) {
            self.text = text
            self.isComplete = isComplete
        }
    }

    /// 문장이 끝났다고 보는 기호. 반각·전각을 모두 받는다 — 전사기가 어느 쪽을 낼지
    /// 미리 알 수 없다.
    private static let terminalPunctuation: Set<Character> = [".", "?", "!", "。", "？", "！"]

    /// 문장부호 없이 말이 계속 이어질 때 한 줄이 감당할 최대 글자 수(안전망).
    ///
    /// 기본 패널 너비(560pt, 좌우 패딩 26pt씩 → 본문 508pt)와 기본 자막 글자 크기
    /// (20pt semibold 시스템 폰트) 기준으로 골랐다. 영문은 한 글자(공백 포함) 평균
    /// 폭이 대략 10~11pt라 한 줄에 46자 안팎, 두 줄에 92자 안팎이 들어간다 — 이
    /// 저장소의 기존 `CaptionText.tail` 기본값 92가 바로 그 수치였다(한 줄짜리
    /// 자막을 2단으로 자르던 시절의 유산). 한글은 완성형 음절 한 글자가 거의
    /// 정사각형이라 영문의 약 두 배(20pt 안팎) 폭을 먹는다 — 그래서 한 줄에 24자
    /// 안팎, 두 줄에 48자 안팎이 한도다. 언어별로 다른 상수를 두지 않고 더 빡빡한
    /// 한글 기준(48)을 공용으로 쓴다: 이 안전망은 "문장부호 없이 계속 늘어나는" 경우를
    /// 위한 것일 뿐이라, 영문에 적용해도 결과는 "필요보다 조금 더 일찍 끊길 수 있다"
    /// 정도다 — 읽기 좋은 쪽으로만 치우치지, 넘치거나 잘리지 않는다.
    public static let defaultCap = 48

    /// - Parameters:
    ///   - text: 발화의 누적 전체 텍스트(지금까지 나온 전부, 델타가 아니다).
    ///   - isFinal: 이 텍스트를 만든 이벤트가 발화의 마지막 조각인가. true면 마지막
    ///     조각도(문장부호가 없어도) 완결로 표시한다 — 발화가 끝났으니 더 안 바뀐다.
    ///   - cap: 안전망이 허용하는 최대 글자 수.
    public static func segment(_ text: String, isFinal: Bool, cap: Int = defaultCap) -> [Segment] {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chars.isEmpty else { return [] }

        var segments: [Segment] = []
        var start = 0
        var i = 0
        while i < chars.count {
            if terminalPunctuation.contains(chars[i]) {
                segments.append(Segment(text: String(chars[start...i]), isComplete: true))
                start = skipWhitespace(chars, from: i + 1)
                i = start
                continue
            }
            if i - start + 1 > cap, let breakAt = lastWordBoundary(chars, from: start, upTo: i) {
                segments.append(Segment(text: String(chars[start..<breakAt]), isComplete: true))
                start = skipWhitespace(chars, from: breakAt + 1)
                i = start
                continue
            }
            i += 1
        }
        if start < chars.count {
            segments.append(Segment(text: String(chars[start...]), isComplete: isFinal))
        }
        return segments
    }

    private static func skipWhitespace(_ chars: [Character], from index: Int) -> Int {
        var i = index
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        return i
    }

    /// `upTo`(한도를 막 넘긴 글자) 이전 구간에서 마지막 공백 위치를 찾는다. 못 찾으면
    /// nil — 공백 없는 한 덩어리는 중간을 억지로 끊지 않고 계속 키운다(스펙 §2:
    /// "단어 경계가 없으면" 자르지 않는다).
    private static func lastWordBoundary(_ chars: [Character], from start: Int, upTo: Int) -> Int? {
        var j = upTo
        while j > start {
            if chars[j].isWhitespace { return j }
            j -= 1
        }
        return nil
    }
}
