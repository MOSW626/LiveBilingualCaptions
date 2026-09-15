import Testing
@testable import CaptionsCore

@Test func 부분과_확정을_구분한다() {
    #expect(Transcript.partial("안녕").isFinal == false)
    #expect(Transcript.final("안녕하세요").isFinal == true)
}

@Test func 텍스트를_꺼낸다() {
    #expect(Transcript.partial("안녕").text == "안녕")
    #expect(Transcript.final("안녕하세요").text == "안녕하세요")
}
