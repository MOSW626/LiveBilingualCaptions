import Testing
@testable import CaptionsCore

@Test func 제한보다_짧으면_그대로() {
    #expect(CaptionText.tail("짧은 문장", limit: 92) == "짧은 문장")
}

@Test func 제한과_같으면_그대로() {
    let text = String(repeating: "가", count: 10)
    #expect(CaptionText.tail(text, limit: 10) == text)
}

@Test func 제한을_넘으면_공백_경계에서_자르고_말줄임표() {
    let result = CaptionText.tail("aaaa bbbb cccc", limit: 9)
    #expect(result.hasPrefix("…"))
    #expect(result == "…cccc")
}

@Test func 공백이_없는_장문은_그냥_뒤에서_자른다() {
    let result = CaptionText.tail(String(repeating: "가", count: 20), limit: 5)
    #expect(result == "…" + String(repeating: "가", count: 5))
}

@Test func 빈_문자열은_빈_문자열() {
    #expect(CaptionText.tail("", limit: 92) == "")
}
