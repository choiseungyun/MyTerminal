import Foundation

/// LG AI연구원 EXAONE API (`POST https://api.exaone.ai/v1/chat/completions`, OpenAI 호환).
///
/// - 시스템 프롬프트·질문은 `messages` (system, user)
/// - JSON 응답: `response_format` = {type: json_schema, json_schema: {name, strict, schema}}.
///   문서(docs.exaone.ai, 2026-11)는 "Structured outputs" 를 지원 기능으로 적었지만 요청 형식은 적지 않아,
///   OpenAI 형식으로 보내고 시스템 프롬프트에도 스키마를 넣는다. 응답은 코드 블록·앞뒤 글자를 걷어 내고 읽는다.
/// - 생각 깊이: `reasoning_effort` (low / high / max, 생각은 항상 켜짐). 목록의 모델만 보낸다.
///   앱의 `low` → `low`, `medium` → `high`
/// - 스트리밍(`stream: true`, SSE)으로 받는다. 생각이 길면 답까지 수십 초가 걸려,
///   한 번에 받으면 그동안 아무 표시도 없고 120초 무응답 제한에 걸릴 수 있다.
///   조각의 `delta.reasoning_content`(생각)는 진행 표시에만 쓰고 `delta.content`(답)만 모은다.
/// - 오류 본문: {"result_code": …, "description": "…"}
struct ExaoneClient: AIClient {
    static let endpoint = URL(string: "https://api.exaone.ai/v1/chat/completions")!

    var session: URLSession = .shared
    var apiKey: () -> String?
    var provider: AIProvider { .exaone }

    static func body(for request: AIRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "messages": [
                ["role": "system", "content": system(for: request)],
                ["role": "user", "content": request.user],
            ],
            "max_tokens": request.maxTokens,
            "stream": true,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "myterminal_answer", "strict": true, "schema": request.schema],
            ],
        ]
        if AIProvider.exaone.isPreset(request.model) {
            body["reasoning_effort"] = request.effort == "low" ? "low" : "high"
        }
        return body
    }

    /// 구조화 출력이 무시되더라도 JSON 으로 답하도록 스키마를 시스템 프롬프트에 붙인다.
    static func system(for request: AIRequest) -> String {
        let schema = (try? JSONSerialization.data(withJSONObject: request.schema, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return request.system + """


        Respond with a single JSON object that matches this JSON Schema, and nothing else (no code fences, no extra text):
        \(schema)
        """
    }

    func send<T: Decodable>(_ request: AIRequest, as type: T.Type) async throws -> T {
        let key = try AIHTTP.key(apiKey, provider)
        let lines = try await AIHTTP.stream(
            provider, Self.endpoint, headers: ["authorization": "Bearer \(key)"],
            body: Self.body(for: request), session: session,
            onRetry: { request.onProgress?(.retrying($0)) })
        var stream = Stream(onProgress: request.onProgress)
        do {
            for try await line in lines {
                if try stream.read(line) { break }
            }
        } catch let error as AIError {
            throw error
        } catch {
            throw AIHTTP.mapTransport(error)
        }
        return try stream.finish(as: type)
    }

    /// SSE 줄을 읽어 답을 모은다.
    struct Stream {
        var onProgress: ((AIProgress) -> Void)?
        private(set) var content = ""
        private(set) var finishReason: String?
        private(set) var refused = false
        private var progress: AIProgress?

        init(onProgress: ((AIProgress) -> Void)? = nil) { self.onProgress = onProgress }

        private struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String?; let reasoning_content: String?; let refusal: String? }
                let delta: Delta?
                let finish_reason: String?
            }
            struct Fault: Decodable { let message: String? }
            let choices: [Choice]?
            let error: Fault?
        }

        /// 한 줄을 읽는다. 끝(`[DONE]`)이면 true.
        mutating func read(_ line: String) throws -> Bool {
            guard line.hasPrefix("data:") else { return false }   // 빈 줄·주석·event: 줄
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return true }
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { return false }
            if let error = chunk.error {
                throw AIError.http(.exaone, status: 0, message: error.message)
            }
            for choice in chunk.choices ?? [] {
                if let reasoning = choice.delta?.reasoning_content, !reasoning.isEmpty { report(.thinking) }
                if let text = choice.delta?.content, !text.isEmpty {
                    content += text
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { report(.answering) }
                }
                if let refusal = choice.delta?.refusal, !refusal.isEmpty { refused = true }
                if let reason = choice.finish_reason { finishReason = reason }
            }
            return false
        }

        private mutating func report(_ next: AIProgress) {
            guard progress != next, progress != .answering else { return }
            progress = next
            onProgress?(next)
        }

        func finish<T: Decodable>(as type: T.Type) throws -> T {
            if refused { throw AIError.refused }
            switch finishReason {
            case "length": throw AIError.truncated
            case "content_filter": throw AIError.refused
            default: break
            }
            return try AIHTTP.decodeJSON(ExaoneClient.extractJSON(content), as: type)
        }
    }

    /// 답에서 JSON 객체 부분만 꺼낸다 (앞의 빈 줄, ```json 코드 블록, 앞뒤 설명 글).
    static func extractJSON(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else { return trimmed }
        return String(trimmed[start...end])
    }
}
