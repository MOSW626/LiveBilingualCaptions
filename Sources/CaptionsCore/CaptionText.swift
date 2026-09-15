import Foundation

public enum CaptionText {
    /// 자막 줄이 넘칠 때 앞을 버리고 뒤를 남긴다. 말은 계속 흐르므로 최신 쪽이 중요하다.
    /// 가능하면 단어 경계에서 자르고, 경계가 없으면 글자 수로 자른다.
    public static func tail(_ text: String, limit: Int = 92) -> String {
        guard text.count > limit else { return text }
        let suffix = String(text.suffix(limit))
        if let space = suffix.firstIndex(of: " ") {
            return "…" + suffix[suffix.index(after: space)...]
        }
        return "…" + suffix
    }
}
