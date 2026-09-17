import Testing
import Foundation
@testable import CaptionsCore

/// `OpenAIRefiner`도 `ClaudeRefiner`와 같은 이유로 실제 네트워크를 타지 않는다 —
/// `Transport`에 가짜 응답을 주입한다.
private func response(status: Int) -> URLResponse {
    HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                    statusCode: status, httpVersion: nil, headerFields: nil)!
}

private actor RequestBox {
    private(set) var request: URLRequest?
    func store(_ request: URLRequest) { self.request = request }
}

@Suite struct OpenAIRefinerTests {

    @Test func 정상_응답에서_텍스트를_뽑아_다듬는다() async throws {
        let body = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": "  다듬은 번역  \n"]]]
        ])
        let refiner = OpenAIRefiner(apiKey: "k", model: "gpt-4o-mini") { _ in
            (body, response(status: 200))
        }
        let result = try await refiner.refine("초안", source: "원문", context: [])
        #expect(result == "다듬은 번역")
    }

    @Test func 요청_본문이_명세대로_구성된다() async throws {
        let body = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": "결과"]]]
        ])
        let box = RequestBox()
        let refiner = OpenAIRefiner(apiKey: "secret-key", model: "gpt-4o-mini") { request in
            await box.store(request)
            return (body, response(status: 200))
        }
        _ = try await refiner.refine("초안", source: "원문", context: ["직전1"])

        let request = try #require(await box.request)
        #expect(request.url == URL(string: "https://api.openai.com/v1/chat/completions"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let sent = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect(json["max_tokens"] as? Int == 300)
        #expect(json["temperature"] as? Int == 0)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        let userContent = try #require(messages[1]["content"] as? String)
        #expect(userContent.contains("직전1"), "문맥이 user 메시지에 실려야 한다")
    }

    @Test func 상태코드가_200이_아니면_에러를_던진다() async throws {
        let refiner = OpenAIRefiner(apiKey: "k", model: "gpt-4o-mini") { _ in
            (Data(), response(status: 500))
        }
        await #expect(throws: OpenAIRefinerError.requestFailed) {
            _ = try await refiner.refine("초안", source: "원문", context: [])
        }
    }

    @Test func 해석할_수_없는_본문은_에러를_던진다() async throws {
        let refiner = OpenAIRefiner(apiKey: "k", model: "gpt-4o-mini") { _ in
            (Data("이건 JSON이 아니다".utf8), response(status: 200))
        }
        await #expect(throws: OpenAIRefinerError.unparseableResponse) {
            _ = try await refiner.refine("초안", source: "원문", context: [])
        }
    }

    @Test func choices가_비어있으면_에러를_던진다() async throws {
        let body = try! JSONSerialization.data(withJSONObject: ["choices": []])
        let refiner = OpenAIRefiner(apiKey: "k", model: "gpt-4o-mini") { _ in
            (body, response(status: 200))
        }
        await #expect(throws: OpenAIRefinerError.unparseableResponse) {
            _ = try await refiner.refine("초안", source: "원문", context: [])
        }
    }

    @Test func 내용이_빈_문자열이면_에러를_던진다() async throws {
        let body = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": "   "]]]
        ])
        let refiner = OpenAIRefiner(apiKey: "k", model: "gpt-4o-mini") { _ in
            (body, response(status: 200))
        }
        await #expect(throws: OpenAIRefinerError.unparseableResponse) {
            _ = try await refiner.refine("초안", source: "원문", context: [])
        }
    }
}
