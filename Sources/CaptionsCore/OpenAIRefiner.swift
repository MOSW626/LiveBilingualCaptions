import Foundation

/// `ClaudeRefiner`와 같은 역할을 OpenAI Chat Completions로 한다. 프롬프트 내용은
/// `RefinementPrompt`를 공유해 두 제공자가 서로 다른 말을 하지 않게 한다.
public struct OpenAIRefiner: TranslationRefiner {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// 사용자가 직접 바꿀 수 있는 기본 모델. OpenAI 모델 ID는 검증하지 않았다 —
    /// 요청이 거부되면 설정에서 모델명을 바꿔야 한다(SettingsView 안내 문구 참고).
    public static let defaultModel = "gpt-4o-mini"

    private let apiKey: String
    private let model: String
    private let transport: Transport
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    public init(apiKey: String, model: String,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public func refine(_ draft: String, source: String, context: [String]) async throws -> String {
        let userContent = RefinementPrompt.content(draft: draft, source: source, context: context)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 6          // 자막이므로 오래 기다리지 않는다
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 300,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": RefinementPrompt.instruction],
                ["role": "user", "content": userContent]
            ]
        ])

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenAIRefinerError.requestFailed
        }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let json = jsonObject as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw OpenAIRefinerError.unparseableResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIRefinerError.unparseableResponse }
        return trimmed
    }
}

enum OpenAIRefinerError: Error, Equatable {
    case requestFailed
    case unparseableResponse
}
