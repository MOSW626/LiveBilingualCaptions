import Foundation

/// **더 이상 `CaptionState.apply`가 쓰지 않는다.** 한 발화 = 한 줄이던 시절의
/// backstop이었다 — 한 줄이 문장 여러 개를 통째로 품을 수 있었으니 넘치면 머리를
/// 잘라야 했다. 지금은 `CaptionSegmenter`가 애초에 문장(또는 `CaptionSegmenter.
/// defaultCap` 안전망) 단위로 줄을 만들기 때문에 `CaptionState`가 내놓는 원문은
/// 이미 그 한도 안에 있다 — 여기 더해 머리까지 자르면 "…"로 시작하는, 이미 알맞게
/// 잘려 있던 문장의 앞부분을 한 번 더 씹어먹을 뿐이다(사용자 스크린샷에서 실제로
/// 관찰된 증상 — 머리는 `tail`이, 꼬리는 `CaptionOverlay`의 `.lineLimit(2)`가 잘라
/// 문장 가운데만 남았다). 그래서 호출부에서 뺐다. 함수 자체와 아래 테스트는 남겨
/// 둔다 — 독립적으로 유용한 순수 함수고(경계 없이 자라는 값을 다루는 다른 곳이
/// 생기면 쓸 수 있다), 지우는 게 목적이 아니라 "두 겹으로 쌓지 않는" 게 목적이다.
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
