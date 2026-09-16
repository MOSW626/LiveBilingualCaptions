import Testing
import Foundation
@testable import CaptionsCore

/// `ClaudeRefiner`는 실제 네트워크를 타지 않는다 — 여기 없는 API 키로는 어차피 못 하고,
/// 매 테스트가 네트워크에 걸리면 CI가 흔들린다. `Transport`에 가짜 응답을 주입한다.
private func response(status: Int) -> URLResponse {
    HTTPURLResponse(url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// `Transport`는 `@Sendable`이라 평범한 `var`를 직접 캡처해 대입할 수 없다 — actor에 담는다.
private actor RequestBox {
    private(set) var request: URLRequest?
    func store(_ request: URLRequest) { self.request = request }
}

@Suite struct ClaudeRefinerTests {

    @Test func 정상_응답에서_텍스트를_뽑아_다듬는다() async throws {
        let body = try! JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "  다듬은 번역  \n"]]
        ])
        let refiner = ClaudeRefiner(apiKey: "k", model: "claude-haiku-4-5") { _ in
            (body, response(status: 200))
        }
        let result = try await refiner.refine("초안", source: "원문", context: [])
        #expect(result == "다듬은 번역")
    }

    @Test func 요청_본문이_명세대로_구성된다() async throws {
        let body = try! JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "결과"]]
        ])
        let box = RequestBox()
        let refiner = ClaudeRefiner(apiKey: "secret-key", model: "claude-haiku-4-5") { request in
            await box.store(request)
            return (body, response(status: 200))
        }
        _ = try await refiner.refine("초안", source: "원문", context: ["직전1"])

        let request = try #require(await box.request)
        #expect(request.url == URL(string: "https://api.anthropic.com/v1/messages"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")

        let sent = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(json["model"] as? String == "claude-haiku-4-5")
        #expect(json["max_tokens"] as? Int == 300)
        #expect(json["output_config"] == nil)
        #expect(json["thinking"] == nil)
    }

    @Test func 텍스트가_아닌_블록은_건너뛴다() async throws {
        let body = try! JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn",
            "content": [
                ["type": "other", "text": "무시되어야 함"],
                ["type": "text", "text": "진짜 텍스트"]
            ]
        ])
        let refiner = ClaudeRefiner(apiKey: "k", model: "claude-haiku-4-5") { _ in
            (body, response(status: 200))
        }
        let result = try await refiner.refine("초안", source: "원문", context: [])
        #expect(result == "진짜 텍스트")
    }

    @Test func 거부_응답은_텍스트로_취급하지_않고_에러를_던진다() async throws {
        // stop_reason이 refusal이면 HTTP 200이어도 보정 없음으로 취급해야 한다.
        // content에 텍스트가 섞여 있어도(모델이 일부만 쓰다 거부한 경우) 그대로 받아들이면 안 된다.
        let body = try! JSONSerialization.data(withJSONObject: [
            "stop_reason": "refusal",
            "content": [["type": "text", "text": "이건 반영되면 안 된다"]]
        ])
        let refiner = ClaudeRefiner(apiKey: "k", model: "claude-haiku-4-5") { _ in
            (body, response(status: 200))
        }
        await #expect(throws: ClaudeRefinerError.refused) {
            _ = try await refiner.refine("초안", source: "원문", context: [])
        }
    }

    @Test func 상태코드가_200이_아니면_에러를_던진다() async throws {
        let refiner = ClaudeRefiner(apiKey: "k", model: "claude-haiku-4-5") { _ in
            (Data(), response(status: 500))
        }
        await #expect(throws: ClaudeRefinerError.requestFailed) {
            _ = try await refiner.refine("초안", source: "원문", context: [])
        }
    }

    @Test func 해석할_수_없는_본문은_에러를_던진다() async throws {
        let refiner = ClaudeRefiner(apiKey: "k", model: "claude-haiku-4-5") { _ in
            (Data("이건 JSON이 아니다".utf8), response(status: 200))
        }
        await #expect(throws: ClaudeRefinerError.unparseableResponse) {
            _ = try await refiner.refine("초안", source: "원문", context: [])
        }
    }

    @Test func content가_없으면_에러를_던진다() async throws {
        let body = try! JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn"])
        let refiner = ClaudeRefiner(apiKey: "k", model: "claude-haiku-4-5") { _ in
            (body, response(status: 200))
        }
        await #expect(throws: ClaudeRefinerError.unparseableResponse) {
            _ = try await refiner.refine("초안", source: "원문", context: [])
        }
    }
}
