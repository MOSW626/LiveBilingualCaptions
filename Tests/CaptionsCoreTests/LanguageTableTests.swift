import Testing
import Foundation
@testable import CaptionsCore

private let table = LanguageTable.default
private let ko = CaptionLanguage.korean
private let en = CaptionLanguage.english

@Test func 한글이_한_글자라도_있으면_한국어() {
    #expect(table.detect("hello 안녕", current: en) == ko)
    #expect(table.detect("안", current: en) == ko)
}

@Test func 라틴만_세_글자_이상이면_영어() {
    #expect(table.detect("hello world", current: ko) == en)
}

@Test func 라틴이_세_글자_미만이면_현재_언어_유지() {
    #expect(table.detect("hi", current: ko) == ko)
    #expect(table.detect("hi", current: en) == en)
}

@Test func 어느_범위에도_안_걸리면_현재_언어_유지() {
    #expect(table.detect("123 !!", current: ko) == ko)
    #expect(table.detect("", current: en) == en)
}

@Test func 번역_대상은_감지된_언어가_아닌_언어() {
    #expect(table.target(for: ko) == en)
    #expect(table.target(for: en) == ko)
}

@Test func 언어를_id로_찾는다() {
    #expect(table.language(id: "ko-KR") == ko)
    #expect(table.language(id: "없음") == nil)
}

@Test func 언어_추가는_배열_한_줄() {
    let ja = CaptionLanguage(
        locale: Locale(identifier: "ja-JP"), displayName: "일본어",
        uniqueRanges: [0x3040...0x309F, 0x30A0...0x30FF], sharedRanges: [])
    let extended = LanguageTable(languages: [ko, en, ja])
    #expect(extended.detect("こんにちは", current: en) == ja)
}

// Additional tests for target(for:preferredID:) with 3+ languages
@Test func 세_언어_이상일_때_기본_대상_선택() {
    let ja = CaptionLanguage(
        locale: Locale(identifier: "ja-JP"), displayName: "일본어",
        uniqueRanges: [0x3040...0x309F, 0x30A0...0x30FF], sharedRanges: [])
    let extended = LanguageTable(languages: [ko, en, ja])
    #expect(extended.target(for: ko, preferredID: "ja-JP") == ja)
}

@Test func 원문과_대상이_모두_같을_때_첫_다른_언어_선택() {
    let ja = CaptionLanguage(
        locale: Locale(identifier: "ja-JP"), displayName: "일본어",
        uniqueRanges: [0x3040...0x309F, 0x30A0...0x30FF], sharedRanges: [])
    let extended = LanguageTable(languages: [ko, en, ja])
    #expect(extended.target(for: ja, preferredID: "ja-JP") == ko)
}

@Test func 없는_대상_ID는_첫_다른_언어_선택() {
    let ja = CaptionLanguage(
        locale: Locale(identifier: "ja-JP"), displayName: "일본어",
        uniqueRanges: [0x3040...0x309F, 0x30A0...0x30FF], sharedRanges: [])
    let extended = LanguageTable(languages: [ko, en, ja])
    #expect(extended.target(for: ko, preferredID: "없음") == en)
}

@Test func 두_언어에서_반대_언어_유지() {
    #expect(table.target(for: ko) == en)
    #expect(table.target(for: en) == ko)
    #expect(table.target(for: ko, preferredID: "ja-JP") == en)
    #expect(table.target(for: en, preferredID: "ko-KR") == ko)
}
