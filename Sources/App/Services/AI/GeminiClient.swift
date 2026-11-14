import Foundation

/// Gemini Interactions API (`POST /v1beta/interactions`, `Api-Revision: 2026-05-20`).
///
/// - 시스템 프롬프트는 `system_instruction`, 질문은 `input`(문자열)
/// - JSON 응답: `response_format` = {type: text, mime_type: application/json, schema}
/// - 생각 깊이: `generation_config.thinking_level` (목록의 모델만)
/// - `store: false` 로 요청 내용을 서버에 남기지 않는다
/// - 응답: `steps` 의 model_output 항목 안 text. 생각(thought) 항목은 건너뛴다.
struct GeminiClient: AIClient {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    static let apiRevision = "2026-05-20"

    var session: URLSession = .shared
    var apiKey: () -> String?
    var provider: AIProvider { .gemini }

    static func body(for request: AIRequest) -> [String: Any] {
        var generation: [String: Any] = ["max_output_tokens": request.maxTokens]
        if AIProvider.gemini.isPreset(request.model) {
            generation["thinking_level"] = request.effort
        }
        return [
            "model": request.model,
            "system_instruction": request.system,
            "input": request.user,
            "store": false,
            "generation_config": generation,
            "response_format": [
                "type": "text",
                "mime_type": "application/json",
                // 문서에 additionalProperties 지원이 명시되어 있지 않아 빼고 보낸다 (응답은 디코딩으로 검사)
                "schema": strippingAdditionalProperties(request.schema),
            ],
        ]
    }

    func send<T: Decodable>(_ request: AIRequest, as type: T.Type) async throws -> T {
        let key = try AIHTTP.key(apiKey, provider)
        let data = try await AIHTTP.post(
            provider, Self.endpoint, headers: ["x-goog-api-key": key, "Api-Revision": Self.apiRevision],
            body: Self.body(for: request), session: session)
        return try Self.decode(data, as: type)
    }

    private struct Response: Decodable {
        struct Step: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let type: String
            let content: [Content]?
        }
        struct Fault: Decodable { let message: String? }
        let status: String?
        let steps: [Step]?
        let errors: [Fault]?
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw AIError.badResponse }
        switch response.status {
        case "incomplete": throw AIError.truncated
        case "failed", "cancelled":
            throw AIError.http(.gemini, status: 0, message: response.errors?.first?.message)
        default: break
        }
        // 마지막 모델 출력의 글자
        guard let output = response.steps?.last(where: { $0.type == "model_output" }) else { throw AIError.badResponse }
        let text = (output.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
        return try AIHTTP.decodeJSON(text, as: type)
    }

    static func strippingAdditionalProperties(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            dict.removeValue(forKey: "additionalProperties")
            return dict.mapValues(strippingAdditionalProperties)
        }
        if let array = value as? [Any] { return array.map(strippingAdditionalProperties) }
        return value
    }
}
