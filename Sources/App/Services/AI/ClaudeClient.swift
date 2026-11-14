import Foundation

/// Claude Messages API (Swift 공식 SDK 가 없어 HTTP 로 직접 부른다).
///
/// 응답은 structured outputs(`output_config.format`)로 JSON 스키마에 맞춰 받는다.
/// 모델은 생각(thinking) 블록을 함께 돌려줄 수 있으므로 text 블록만 골라 읽는다.
struct ClaudeClient: AIClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"

    var session: URLSession = .shared
    var apiKey: () -> String?
    var provider: AIProvider { .anthropic }

    static func body(for request: AIRequest) -> [String: Any] {
        [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
            "output_config": [
                "effort": request.effort,
                "format": ["type": "json_schema", "schema": request.schema],
            ],
        ]
    }

    func send<T: Decodable>(_ request: AIRequest, as type: T.Type) async throws -> T {
        let key = try AIHTTP.key(apiKey, provider)
        let data = try await AIHTTP.post(
            provider, Self.endpoint,
            headers: ["x-api-key": key, "anthropic-version": Self.apiVersion],
            body: Self.body(for: request), session: session)
        return try Self.decode(data, as: type)
    }

    private struct Response: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
        let stop_reason: String?
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        guard let message = try? JSONDecoder().decode(Response.self, from: data) else { throw AIError.badResponse }
        switch message.stop_reason {
        case "refusal": throw AIError.refused
        case "max_tokens": throw AIError.truncated
        default: break
        }
        let text = message.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        return try AIHTTP.decodeJSON(text, as: type)
    }
}
