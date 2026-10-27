import Foundation

/// Claude·OpenAI 두 보정기가 공유하는 프롬프트 내용.
/// 같은 지시문을 두 파일에 따로 적으면 한쪽만 고치고 잊어버리는 사고가 난다 —
/// 여기 하나만 고치면 두 제공자 모두 같이 바뀐다.
enum RefinementPrompt {
    /// 모델의 역할·제약을 정의하는 고정 지시문. Claude는 사용자 메시지 앞에 붙이고,
    /// OpenAI는 system 메시지로 그대로 보낸다 — 내용은 같다.
    static let instruction = """
    실시간 자막의 기계 번역을 다듬어라. "직전 대화"는 같은 화자가 방금까지 말한 문장들과 \
    그때 채택된 번역이다 — 같은 대화의 연속이니 고유명사·기술 용어·존댓말 톤을 그 번역들과 \
    일관되게 유지하라.

    출력은 반드시 "이번 기계 번역"과 같은 언어로 쓴다 — 원문 언어로 되돌리지 마라.
    문맥에 맞춰 자연스럽게 고친 번역문만 출력하라. 설명·따옴표·접두어를 붙이지 마라.
    내용을 추가하거나 빼지 마라. 고칠 것이 없으면 기계 번역을 그대로 출력하라.
    """

    /// 요청 하나에 실릴 가변 내용(문맥 쌍·원문·초안).
    static func content(draft: String, source: String, context: [String]) -> String {
        let contextBlock = context.isEmpty ? "(없음)" : context.joined(separator: "\n\n")
        return """
        직전 대화:
        \(contextBlock)

        이번 원문: \(source)
        이번 기계 번역: \(draft)
        """
    }
}
