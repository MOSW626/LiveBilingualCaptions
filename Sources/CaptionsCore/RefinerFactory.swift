import Foundation

/// `AppDelegate.updateRefiner()`가 실제로 쓰는 선택 로직을 AppKit 없이 테스트하려고 뺐다.
/// 보정이 꺼져 있거나, 선택된 제공자의 키가 없으면 nil을 돌려준다 — 호출부는 그 결과를
/// `Translator.refiner`에 그대로 대입하면 된다.
public enum RefinerFactory {
    public static func makeRefiner(settings: Settings, anthropicKey: String?,
                                   openAIKey: String?, anthropicModel: String) -> TranslationRefiner? {
        guard settings.refinementEnabled else { return nil }
        switch settings.refinementProvider {
        case .claude:
            guard let key = anthropicKey, !key.isEmpty else { return nil }
            return ClaudeRefiner(apiKey: key, model: anthropicModel)
        case .openai:
            guard let key = openAIKey, !key.isEmpty else { return nil }
            return OpenAIRefiner(apiKey: key, model: settings.openAIModel)
        }
    }
}
