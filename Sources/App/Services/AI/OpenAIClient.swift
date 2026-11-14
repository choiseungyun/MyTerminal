import Foundation

/// OpenAI Responses API (`POST /v1/responses`).
///
/// - 시스템 프롬프트는 `instructions`, 질문은 `input`(문자열)
/// - JSON 응답: `text.format` = {type: json_schema, name, strict: true, schema}
/// - 생각 깊이: `reasoning.effort` (목록의 모델만. 직접 입력한 모델은 지원 여부를 몰라 보내지 않는다)
/// - `store: false` 로 요청 내용을 OpenAI 서버에 남기지 않는다
/// - 응답: `output` 의 message 항목 안 `output_text`(답) / `refusal`(거절). 생각(reasoning) 항목은 건너뛴다.
struct OpenAIClient: AIClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    var session: URLSession = .shared
    var apiKey: () -> String?
    var provider: AIProvider { .openai }

    static func body(for request: AIRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "instructions": request.system,
            "input": request.user,
            "max_output_tokens": request.maxTokens,
            "store": false,
            "text": ["format": [
                "type": "json_schema",
                "name": "myterminal_answer",
                "strict": true,
                "schema": request.schema,
            ]],
        ]
        if AIProvider.openai.isPreset(request.model) {
            body["reasoning"] = ["effort": request.effort]
        }
        return body
    }

    func send<T: Decodable>(_ request: AIRequest, as type: T.Type) async throws -> T {
        let key = try AIHTTP.key(apiKey, provider)
        let data = try await AIHTTP.post(
            provider, Self.endpoint, headers: ["authorization": "Bearer \(key)"],
            body: Self.body(for: request), session: session)
        return try Self.decode(data, as: type)
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            struct Part: Decodable { let type: String; let text: String?; let refusal: String? }
            let type: String
            let content: [Part]?
        }
        struct Incomplete: Decodable { let reason: String? }
        let status: String?
        let output: [Item]?
        let incomplete_details: Incomplete?
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw AIError.badResponse }
        let parts = (response.output ?? []).filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        if parts.contains(where: { $0.type == "refusal" }) { throw AIError.refused }
        if response.status == "incomplete" {
            throw response.incomplete_details?.reason == "content_filter" ? AIError.refused : AIError.truncated
        }
        let text = parts.filter { $0.type == "output_text" }.compactMap(\.text).joined()
        return try AIHTTP.decodeJSON(text, as: type)
    }
}
