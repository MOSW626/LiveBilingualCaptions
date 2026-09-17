import Testing
import Foundation
@testable import CaptionsCore

/// `AppDelegate.updateRefiner()`가 실제로 쓰는 선택 로직(`RefinerFactory`)을
/// AppKit 없이 검증한다: 보정 on/off, 제공자 선택, 키 유무의 조합.
@Suite struct RefinerFactoryTests {

    @Test func 보정이_꺼져있으면_키가_있어도_nil() {
        var settings = Settings.default
        settings.refinementEnabled = false
        settings.refinementProvider = .claude
        let refiner = RefinerFactory.makeRefiner(
            settings: settings, anthropicKey: "k", openAIKey: "k", anthropicModel: "claude-haiku-4-5")
        #expect(refiner == nil)
    }

    @Test func claude_선택시_anthropic_키가_있으면_ClaudeRefiner() {
        var settings = Settings.default
        settings.refinementEnabled = true
        settings.refinementProvider = .claude
        let refiner = RefinerFactory.makeRefiner(
            settings: settings, anthropicKey: "k", openAIKey: nil, anthropicModel: "claude-haiku-4-5")
        #expect(refiner is ClaudeRefiner)
    }

    @Test func claude_선택시_anthropic_키가_없으면_nil() {
        var settings = Settings.default
        settings.refinementEnabled = true
        settings.refinementProvider = .claude
        let refiner = RefinerFactory.makeRefiner(
            settings: settings, anthropicKey: nil, openAIKey: "openai-key", anthropicModel: "claude-haiku-4-5")
        #expect(refiner == nil, "OpenAI 키가 있어도 선택된 제공자가 Claude면 쓰지 않는다")
    }

    @Test func openai_선택시_openai_키가_있으면_OpenAIRefiner() {
        var settings = Settings.default
        settings.refinementEnabled = true
        settings.refinementProvider = .openai
        settings.openAIModel = "gpt-4o-mini"
        let refiner = RefinerFactory.makeRefiner(
            settings: settings, anthropicKey: "anthropic-key", openAIKey: "k", anthropicModel: "claude-haiku-4-5")
        #expect(refiner is OpenAIRefiner)
    }

    @Test func openai_선택시_openai_키가_없으면_nil() {
        var settings = Settings.default
        settings.refinementEnabled = true
        settings.refinementProvider = .openai
        let refiner = RefinerFactory.makeRefiner(
            settings: settings, anthropicKey: "anthropic-key", openAIKey: nil, anthropicModel: "claude-haiku-4-5")
        #expect(refiner == nil, "Claude 키가 있어도 선택된 제공자가 OpenAI면 쓰지 않는다")
    }

    @Test func openai_선택시_빈_문자열_키는_없는_것으로_취급한다() {
        var settings = Settings.default
        settings.refinementEnabled = true
        settings.refinementProvider = .openai
        let refiner = RefinerFactory.makeRefiner(
            settings: settings, anthropicKey: nil, openAIKey: "", anthropicModel: "claude-haiku-4-5")
        #expect(refiner == nil)
    }
}
