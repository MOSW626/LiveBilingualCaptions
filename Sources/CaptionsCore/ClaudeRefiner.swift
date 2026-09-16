import Foundation

/// 확정된 문장의 온디바이스 번역을 문맥을 보고 다듬는다.
/// 부분 전사에는 절대 호출되지 않는다 — `Translator` 가 `.final` 에서만 부른다.
public struct ClaudeRefiner: TranslationRefiner {
    /// 실제 네트워크 호출부. 테스트가 가짜를 주입할 수 있도록 분리했다 —
    /// `refine` 이 `URLSession.shared` 를 직접 부르면 네트워크 없이는 테스트할 수 없다.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let apiKey: String
    private let model: String
    private let transport: Transport
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public func refine(_ draft: String, source: String, context: [String]) async throws -> String {
        let contextBlock = context.isEmpty ? "(없음)" : context.joined(separator: "\n")
        let prompt = """
        실시간 자막의 기계 번역을 다듬어라.

        직전 문장들:
        \(contextBlock)

        원문: \(source)
        기계 번역: \(draft)

        자연스럽게 고친 번역문만 출력하라. 설명·따옴표·접두어를 붙이지 마라.
        내용을 추가하거나 빼지 마라. 고칠 것이 없으면 기계 번역을 그대로 출력하라.
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 6          // 자막이므로 오래 기다리지 않는다
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 300,
            "messages": [["role": "user", "content": prompt]]
        ])

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClaudeRefinerError.requestFailed
        }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let json = jsonObject as? [String: Any] else {
            throw ClaudeRefinerError.unparseableResponse
        }
        // 거부는 HTTP 200 + stop_reason: "refusal" 로 온다. content 를 읽기 전에 먼저 확인한다 —
        // 그렇지 않으면 거부 응답의 부스러기를 번역문으로 착각할 수 있다.
        if let stopReason = json["stop_reason"] as? String, stopReason == "refusal" {
            throw ClaudeRefinerError.refused
        }
        guard let content = json["content"] as? [[String: Any]] else {
            throw ClaudeRefinerError.unparseableResponse
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw ClaudeRefinerError.unparseableResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ClaudeRefinerError: Error, Equatable {
    case requestFailed
    case unparseableResponse
    case refused
}
