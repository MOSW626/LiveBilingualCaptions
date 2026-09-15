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
