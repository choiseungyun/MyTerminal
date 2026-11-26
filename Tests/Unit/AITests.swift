import AppKit
import SwiftUI
import XCTest
@testable import MyTerminal

// MARK: - 네트워크 대역

/// URLSession 요청을 가로채 정해 둔 응답을 돌려준다.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status = 200
        var body: Data
    }
    static var stub: Stub?
    /// 차례로 돌려줄 응답 (비면 stub)
    static var queue: [Stub] = []
    static var lastRequest: URLRequest?
    static var lastBody: [String: Any]?
    static var requestCount = 0

    static func reset() {
        stub = nil
        queue = []
        lastRequest = nil
        lastBody = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else if let body = request.httpBody {
            Self.lastBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
        let stub = Self.queue.isEmpty ? (Self.stub ?? Stub(status: 500, body: Data())) : Self.queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Messages API 응답 (생각 블록 + JSON text 블록)
    static func messageBody(json: String, stopReason: String = "end_turn") -> Data {
        let response: [String: Any] = [
            "id": "msg_test", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
            "content": [
                ["type": "thinking", "thinking": "", "signature": "sig"],
                ["type": "text", "text": json],
            ],
            "stop_reason": stopReason,
            "usage": ["input_tokens": 10, "output_tokens": 20],
        ]
        return try! JSONSerialization.data(withJSONObject: response)
    }
}

// MARK: - 민감 정보 가림

final class SecretRedactorTests: XCTestCase {
    func testMasksCommonSecrets() {
        let input = """
        DB_PASSWORD=hunter2
        export API_KEY="abc123secret"
        curl -H "Authorization: Bearer eyJhbGciOi.abc" https://x
        git clone https://deploy:s3cr3t@git.example.com/repo.git
        token: ghp_EXAMPLEnotArealTOKEN00000
        aws AKIAIOSFODNN7EXAMPLE
        key sk-ant-EXAMPLE-not-a-real-key
        mysql --password=topsecret -u root
        """
        let (out, count) = SecretRedactor.redact(input)
        for secret in ["hunter2", "abc123secret", "eyJhbGciOi.abc", "s3cr3t", "ghp_EXAMPLEnotArealTOKEN00000",
                       "AKIAIOSFODNN7EXAMPLE", "sk-ant-EXAMPLE-not-a-real-key", "topsecret"] {
            XCTAssertFalse(out.contains(secret), "\(secret) 가 남음:\n\(out)")
        }
        XCTAssertGreaterThanOrEqual(count, 8)
        XCTAssertTrue(out.contains("DB_PASSWORD=[가림]"), "키 이름은 남긴다")
        XCTAssertTrue(out.contains("https://deploy:[가림]@git.example.com"), out)
    }

    func testPrivateKeyBlock() {
        let input = "앞\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAB3NzaC1\nzzz\n-----END OPENSSH PRIVATE KEY-----\n뒤"
        let (out, count) = SecretRedactor.redact(input)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(out, "앞\n[가림]\n뒤")
    }

    func testLeavesOrdinaryOutputAlone() {
        let input = "Permission denied (publickey).\nls: /var/log/nginx: No such file or directory\nexit code 255"
        let (out, count) = SecretRedactor.redact(input)
        XCTAssertEqual(out, input)
        XCTAssertEqual(count, 0)
    }
}

// MARK: - 위험 명령·응답 형식

final class AICommandTests: XCTestCase {
    func testDangerousCommandsAreFlagged() {
        for command in ["rm -rf /var/www", "sudo rm -r build", "dd if=/dev/zero of=/dev/sda", "mkfs.ext4 /dev/sdb1",
                        "git push origin main --force", "curl -fsSL https://x.sh | sudo bash", "shutdown -h now",
                        "mysql -e 'DROP DATABASE prod'", "git reset --hard HEAD~3"] {
            XCTAssertNotNil(DangerousCommand.check(command), command)
        }
        for command in ["ls -la", "du -sh * | sort -h", "tail -n 100 /var/log/syslog", "grep -r password .",
                        "rm file.txt", "git push origin main"] {
            XCTAssertNil(DangerousCommand.check(command), command)
        }
    }

    func testEffectiveRiskAndInsert() {
        let deleting = AICommand(command: "rm -rf ./cache", explanation: "", risk: .low)
        XCTAssertEqual(deleting.effectiveRisk, .high, "모델이 낮게 매겨도 위험 명령은 높인다")
        XCTAssertEqual(AICommand(command: "ls", explanation: "", risk: .medium).effectiveRisk, .medium)
        XCTAssertTrue(AICommand(command: "ls -la", explanation: "", risk: .low).canInsert)
        XCTAssertFalse(AICommand(command: "echo a\necho b", explanation: "", risk: .low).canInsert, "여러 줄은 실행될 수 있어 입력 금지")
        XCTAssertFalse(AICommand(command: "", explanation: "설정 확인", risk: .low).canInsert)
    }

    func testContextDescriptions() {
        let local = AIPaneContext(target: nil, directory: "/Users/me/proj", localOS: "15.1", localShell: "zsh")
        XCTAssertEqual(local.label, "로컬 · /Users/me/proj")
        XCTAssertTrue(local.promptDescription.contains("macOS 15.1, zsh"))

        let remote = AIPaneContext(target: SSHCommand.launch(for: QuickConnectTarget("deploy@web-01")!), directory: nil)
        XCTAssertEqual(remote.label, "web-01")
        XCTAssertTrue(remote.promptDescription.contains("원격 서버"))
        XCTAssertTrue(remote.promptDescription.contains("deploy"))
    }

    /// 스키마의 모든 object 에 additionalProperties: false (structured outputs 요구 사항)
    func testSchemasCloseAllObjects() {
        func check(_ schema: Any, path: String) {
            guard let dict = schema as? [String: Any] else { return }
            if dict["type"] as? String == "object" {
                XCTAssertEqual(dict["additionalProperties"] as? Bool, false, path)
                let required = Set(dict["required"] as? [String] ?? [])
                let properties = dict["properties"] as? [String: Any] ?? [:]
                XCTAssertEqual(required, Set(properties.keys), "\(path): 모든 속성 필수")
                properties.forEach { check($0.value, path: path + "." + $0.key) }
            }
            if let items = dict["items"] { check(items, path: path + "[]") }
        }
        check(AIPrompts.suggestionsSchema, path: "suggestions")
        check(AIPrompts.answerSchema, path: "answer")
    }
}

// MARK: - API 호출

final class ClaudeClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func client(key: String? = "sk-ant-test") -> ClaudeClient {
        ClaudeClient(session: StubURLProtocol.session, apiKey: { key })
    }

    private var request: AIRequest {
        AIRequest(model: "claude-opus-5-5", system: "sys", user: "질문",
                  schema: AIPrompts.suggestionsSchema, effort: "low", maxTokens: 4000)
    }

    func testRequestShapeAndDecoding() async throws {
        StubURLProtocol.stub = .init(body: StubURLProtocol.messageBody(
            json: #"{"commands":[{"command":"du -sh *","explanation":"폴더 크기","risk":"low"}],"note":""}"#))

        let result = try await client().send(request, as: AISuggestions.self)
        XCTAssertEqual(result.commands.first?.command, "du -sh *")
        XCTAssertEqual(result.commands.first?.risk, .low)

        let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(sent.url, ClaudeClient.endpoint)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 4000)
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertNil(body["thinking"], "Opus 5.5 는 thinking 을 보내지 않는다 (항상 켜짐)")
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "low")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil(format["schema"] as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "질문")
    }

    func testMissingKeyDoesNotCallNetwork() async {
        do {
            _ = try await client(key: "  ").send(request, as: AISuggestions.self)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AIError, .missingAPIKey(.anthropic))
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testHTTPErrorsAndStopReasons() async {
        StubURLProtocol.stub = .init(status: 401, body: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        do { _ = try await client().send(request, as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .http(.anthropic, status: 401, message: "invalid x-api-key"))
            XCTAssertTrue(error.localizedDescription.contains("API 키가 올바르지 않습니다"))
        }

        StubURLProtocol.stub = .init(body: StubURLProtocol.messageBody(json: "", stopReason: "refusal"))
        do { _ = try await client().send(request, as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .refused)
        }

        StubURLProtocol.stub = .init(body: StubURLProtocol.messageBody(json: #"{"commands":["#, stopReason: "max_tokens"))
        do { _ = try await client().send(request, as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .truncated)
        }

        StubURLProtocol.stub = .init(body: StubURLProtocol.messageBody(json: "그냥 글"))
        do { _ = try await client().send(request, as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .badResponse)
        }
    }
}

// MARK: - ChatGPT · Gemini

final class OtherProviderClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func request(_ model: String, effort: String = "low") -> AIRequest {
        AIRequest(model: model, system: "sys", user: "질문", schema: AIPrompts.suggestionsSchema, effort: effort, maxTokens: 8000)
    }

    private static let suggestionJSON = #"{"commands":[{"command":"df -h","explanation":"디스크","risk":"low"}],"note":""}"#

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testOpenAIRequestShapeAndDecoding() async throws {
        StubURLProtocol.stub = .init(body: json([
            "id": "resp_1", "object": "response", "status": "completed",
            "output": [
                ["type": "reasoning", "id": "rs_1", "summary": []],
                ["type": "message", "role": "assistant",
                 "content": [["type": "output_text", "text": Self.suggestionJSON, "annotations": []]]],
            ],
        ]))
        let client = OpenAIClient(session: StubURLProtocol.session, apiKey: { "sk-test" })
        let result = try await client.send(request("gpt-6.1-sol"), as: AISuggestions.self)
        XCTAssertEqual(result.commands.first?.command, "df -h")

        let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertEqual(body["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(body["instructions"] as? String, "sys")
        XCTAssertEqual(body["input"] as? String, "질문")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 8000)
        XCTAssertEqual(body["store"] as? Bool, false, "요청을 서버에 저장하지 않는다")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertNotNil(format["name"] as? String)
        XCTAssertEqual((format["schema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
    }

    func testOpenAICustomModelOmitsReasoningAndHandlesStops() async {
        XCTAssertNil(OpenAIClient.body(for: request("my-finetune"))["reasoning"], "직접 입력한 모델은 지원 여부를 몰라 보내지 않는다")
        let client = OpenAIClient(session: StubURLProtocol.session, apiKey: { "sk-test" })

        StubURLProtocol.stub = .init(body: json([
            "status": "completed",
            "output": [["type": "message", "content": [["type": "refusal", "refusal": "도울 수 없습니다"]]]],
        ]))
        do { _ = try await client.send(request("gpt-6-luna"), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .refused)
        }

        StubURLProtocol.stub = .init(body: json([
            "status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": [],
        ]))
        do { _ = try await client.send(request("gpt-6-luna"), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .truncated)
        }

        StubURLProtocol.stub = .init(status: 401, body: Data(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#.utf8))
        do { _ = try await client.send(request("gpt-6-luna"), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .http(.openai, status: 401, message: "Incorrect API key provided"))
        }

        do { _ = try await OpenAIClient(session: StubURLProtocol.session, apiKey: { nil }).send(request("gpt-6-luna"), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .missingAPIKey(.openai))
        }
    }

    func testGeminiRequestShapeAndDecoding() async throws {
        StubURLProtocol.stub = .init(body: json([
            "id": "int_1", "object": "interaction", "status": "completed",
            "steps": [
                ["type": "user_input", "content": [["type": "text", "text": "질문"]]],
                ["type": "thought", "signature": "sig"],
                ["type": "model_output", "content": [["type": "text", "text": Self.suggestionJSON]]],
            ],
        ]))
        let client = GeminiClient(session: StubURLProtocol.session, apiKey: { "AIza-test" })
        let result = try await client.send(request("gemini-3.8-flash"), as: AISuggestions.self)
        XCTAssertEqual(result.commands.first?.command, "df -h")

        let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(sent.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/interactions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Api-Revision"), "2026-05-20")
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertEqual(body["model"] as? String, "gemini-3.8-flash")
        XCTAssertEqual(body["system_instruction"] as? String, "sys")
        XCTAssertEqual(body["input"] as? String, "질문")
        XCTAssertEqual(body["store"] as? Bool, false)
        let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
        XCTAssertEqual(generation["max_output_tokens"] as? Int, 8000)
        XCTAssertEqual(generation["thinking_level"] as? String, "low")
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "text")
        XCTAssertEqual(format["mime_type"] as? String, "application/json")
        let schemaText = String(data: try JSONSerialization.data(withJSONObject: format["schema"]!), encoding: .utf8)!
        XCTAssertFalse(schemaText.contains("additionalProperties"), "문서에 없는 키워드는 빼고 보낸다")
        XCTAssertTrue(schemaText.contains("required"))
    }

    /// 402: 결제 안내 + 서버 메시지 (Google 은 오류를 배열로 보내기도 한다)
    func testPaymentRequiredShowsBillingGuideAndServerMessage() async {
        let client = GeminiClient(session: StubURLProtocol.session, apiKey: { "AIza-test" })
        StubURLProtocol.stub = .init(status: 402, body: Data(#"[{"error":{"code":402,"message":"Billing is not enabled for this project.","status":"FAILED_PRECONDITION"}}]"#.utf8))
        do { _ = try await client.send(request("gemini-4-carbon"), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .http(.gemini, status: 402, message: "Billing is not enabled for this project."))
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("결제가 필요합니다"), text)
            XCTAssertTrue(text.contains("aistudio.google.com"), text)
            XCTAssertTrue(text.contains("서버 메시지: Billing is not enabled"), text)
        }
    }

    func testErrorMessageFallbacks() {
        XCTAssertEqual(AIHTTP.errorMessage(Data(#"{"error":{"message":"m1"}}"#.utf8)), "m1")
        XCTAssertEqual(AIHTTP.errorMessage(Data(#"[{"error":{"message":"m2"}}]"#.utf8)), "m2")
        XCTAssertEqual(AIHTTP.errorMessage(Data(#"{"error":{"code":"x","status":"PERMISSION_DENIED"}}"#.utf8)), "PERMISSION_DENIED")
        XCTAssertEqual(AIHTTP.errorMessage(Data("Payment Required".utf8)), "Payment Required", "JSON 이 아니면 글자 그대로")
        XCTAssertNil(AIHTTP.errorMessage(Data()))
    }

    func testGeminiStatuses() async {
        let client = GeminiClient(session: StubURLProtocol.session, apiKey: { "AIza-test" })
        XCTAssertNil((GeminiClient.body(for: request("gemini-2.0-custom"))["generation_config"] as? [String: Any])?["thinking_level"])

        StubURLProtocol.stub = .init(body: json(["status": "incomplete", "steps": []]))
        do { _ = try await client.send(request("gemini-3.8-flash"), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .truncated)
        }

        StubURLProtocol.stub = .init(body: json(["status": "failed", "steps": [], "errors": [["code": "x", "message": "모델 오류"]]]))
        do { _ = try await client.send(request("gemini-3.8-flash"), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .http(.gemini, status: 0, message: "모델 오류"))
        }
    }
}

// MARK: - EXAONE

final class ExaoneClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func request(_ model: String = "k-exaone_v2.5", effort: String = "low") -> AIRequest {
        AIRequest(model: model, system: "sys", user: "질문", schema: AIPrompts.suggestionsSchema, effort: effort, maxTokens: 8000)
    }

    /// SSE 응답: 생각 조각 → 답을 두 조각으로 → finish_reason → [DONE]
    private func completion(_ content: String, finish: String = "stop") -> Data {
        func event(_ object: [String: Any]) -> String {
            "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
        }
        func delta(_ d: [String: Any]) -> String { event(["choices": [["index": 0, "delta": d]]]) }
        let half = content.index(content.startIndex, offsetBy: content.count / 2)
        var text = delta(["role": "assistant", "content": ""])
        text += delta(["reasoning_content": "생각 {\"x\":1}"])
        text += delta(["content": String(content[..<half])])
        text += delta(["content": String(content[half...])])
        text += event(["choices": [["index": 0, "delta": [:], "finish_reason": finish]]])
        text += event(["choices": [], "usage": ["completion_tokens": 10]])
        text += "data: [DONE]\n\n"
        return Data(text.utf8)
    }

    private var client: ExaoneClient { ExaoneClient(session: StubURLProtocol.session, apiKey: { "ex-test" }) }

    func testRequestShapeAndDecoding() async throws {
        StubURLProtocol.stub = .init(body: completion("\n\n" + #"{"commands":[{"command":"df -h","explanation":"디스크","risk":"low"}],"note":""}"#))
        let result = try await client.send(request(), as: AISuggestions.self)
        XCTAssertEqual(result.commands.first?.command, "df -h", "생각(reasoning_content)은 건너뛰고 앞 빈 줄은 무시")

        let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.exaone.ai/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "authorization"), "Bearer ex-test")
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertEqual(body["model"] as? String, "k-exaone_v2.5")
        XCTAssertEqual(body["max_tokens"] as? Int, 8000)
        XCTAssertEqual(body["stream"] as? Bool, true, "생각이 길어 스트리밍으로 받는다")
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertTrue((messages[0]["content"] as? String)?.hasPrefix("sys") == true)
        XCTAssertTrue((messages[0]["content"] as? String)?.contains("\"commands\"") == true, "스키마를 시스템 프롬프트에도 넣는다")
        XCTAssertEqual(messages[1]["content"] as? String, "질문")
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil((format["json_schema"] as? [String: Any])?["schema"])
    }

    func testEffortMapping() {
        XCTAssertEqual(ExaoneClient.body(for: request(effort: "medium"))["reasoning_effort"] as? String, "high")
        XCTAssertNil(ExaoneClient.body(for: request("exaone-custom"))["reasoning_effort"], "직접 입력한 모델은 보내지 않는다")
    }

    func testExtractsJSONFromCodeFence() async throws {
        StubURLProtocol.stub = .init(body: completion("다음과 같습니다.\n```json\n" + #"{"commands":[],"note":"없음"}"# + "\n```"))
        let result = try await client.send(request(), as: AISuggestions.self)
        XCTAssertEqual(result.note, "없음")
    }

    func testStopsAndErrors() async {
        StubURLProtocol.stub = .init(body: completion(#"{"commands":["#, finish: "length"))
        do { _ = try await client.send(request(), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .truncated)
        }
        StubURLProtocol.stub = .init(body: completion("", finish: "content_filter"))
        do { _ = try await client.send(request(), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .refused)
        }
        StubURLProtocol.stub = .init(body: completion("JSON 이 아닌 답"))
        do { _ = try await client.send(request(), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .badResponse)
        }
        StubURLProtocol.stub = .init(status: 401, body: Data(#"{"result_code":401,"description":"Invalid API key"}"#.utf8))
        do { _ = try await client.send(request(), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .http(.exaone, status: 401, message: "Invalid API key"))
            XCTAssertTrue(error.localizedDescription.hasPrefix("EXAONE API 키가 올바르지 않습니다"), error.localizedDescription)
        }
        do { _ = try await ExaoneClient(session: StubURLProtocol.session, apiKey: { nil }).send(request(), as: AISuggestions.self); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .missingAPIKey(.exaone))
        }
    }

    func testReportsProgressOnce() async throws {
        StubURLProtocol.stub = .init(body: completion(#"{"commands":[],"note":"없음"}"#))
        final class Box { var values: [AIProgress] = [] }
        let box = Box()
        var request = request()
        request.onProgress = { box.values.append($0) }
        _ = try await client.send(request, as: AISuggestions.self)
        XCTAssertEqual(box.values, [.thinking, .answering], "단계가 바뀔 때만 알린다")
    }

    func testStreamErrorAndMissingDone() throws {
        var stream = ExaoneClient.Stream()
        XCTAssertThrowsError(try stream.read(#"data: {"error":{"message":"overloaded"}}"#)) {
            XCTAssertEqual($0 as? AIError, .http(.exaone, status: 0, message: "overloaded"))
        }
        // [DONE] 없이 연결이 끝나도 모은 답을 읽는다. 빈 줄·다른 줄은 건너뛴다.
        var ok = ExaoneClient.Stream()
        XCTAssertFalse(try ok.read(""))
        XCTAssertFalse(try ok.read(": keep-alive"))
        XCTAssertFalse(try ok.read(#"data: {"choices":[{"delta":{"content":"{\"commands\":[],\"note\":\"a\"}"}}]}"#))
        XCTAssertEqual(try ok.finish(as: AISuggestions.self).note, "a")
    }

    func testSubjectParticle() {
        XCTAssertEqual(AIProvider.exaone.subject, "EXAONE이")
        XCTAssertEqual(AIProvider.anthropic.subject, "Claude가")
        XCTAssertTrue(AIError.http(.exaone, status: 400, message: nil).localizedDescription.hasPrefix("EXAONE이 요청을"))
    }
}

final class AISettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AISettingsTests")
        defaults.removePersistentDomain(forName: "AISettingsTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "AISettingsTests")
        super.tearDown()
    }

    func testKeysAndModelsArePerProvider() {
        let settings = AISettings(defaults: defaults, keyStore: .memory([.openai: "sk-o"]))
        XCTAssertEqual(settings.provider, .anthropic, "기본은 Claude")
        XCTAssertFalse(settings.hasAPIKey)
        XCTAssertTrue(settings.hasKey(.openai))

        settings.provider = .openai
        XCTAssertTrue(settings.hasAPIKey)
        XCTAssertEqual(settings.model, "gpt-6-astra")
        settings.setModel("gpt-6.1-terra", for: .openai, .suggest)
        XCTAssertEqual(settings.suggestModel, "gpt-6.1-terra")
        XCTAssertEqual(settings.model(for: .anthropic, .suggest), "claude-opus-5-5", "다른 제공자에 영향 없음")

        settings.saveAPIKey(" AIza-g ", for: .gemini)
        XCTAssertEqual(settings.apiKey(.gemini), "AIza-g")
        settings.deleteAPIKey(for: .openai)
        XCTAssertFalse(settings.hasAPIKey)

        // 다시 읽어도 유지
        let reloaded = AISettings(defaults: defaults, keyStore: .memory([.gemini: "AIza-g"]))
        XCTAssertEqual(reloaded.provider, .openai)
        XCTAssertEqual(reloaded.suggestModel, "gpt-6.1-terra")
        XCTAssertTrue(reloaded.hasKey(.gemini))
    }

    func testMigratesOldClaudeModelSettings() {
        defaults.set("claude-haiku-5-5", forKey: "ai.suggestModel")
        let settings = AISettings(defaults: defaults, keyStore: .memory())
        XCTAssertEqual(settings.model(for: .anthropic, .suggest), "claude-haiku-5-5")
        XCTAssertEqual(settings.model(for: .anthropic, .explain), "claude-opus-5-5")
    }

    func testPresetsAreDistinct() {
        for provider in AIProvider.allCases {
            XCTAssertEqual(Set(provider.presets.map(\.id)).count, provider.presets.count)
            XCTAssertTrue(provider.isPreset(provider.defaultModel))
        }
        XCTAssertEqual(Set(AIProvider.allCases.map(\.keychainAccount)).count, AIProvider.allCases.count)
    }
}

// MARK: - AI 화면 상태

final class AIAssistantTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AIAssistantTests")
        defaults.removePersistentDomain(forName: "AIAssistantTests")
    }

    override func tearDown() {
        StubURLProtocol.reset()
        defaults.removePersistentDomain(forName: "AIAssistantTests")
        super.tearDown()
    }

    private func assistant(key: String? = "sk-ant-test", confirm: Bool = true) -> AIAssistant {
        let settings = AISettings(defaults: defaults, keyStore: .memory(key.map { [.anthropic: $0] } ?? [:]))
        settings.confirmBeforeSend = confirm
        return AIAssistant(settings: settings) { provider in
            AIAssistant.defaultClient(provider, session: StubURLProtocol.session, apiKey: { settings.apiKey(provider) })
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private let context = AIPaneContext(target: nil, directory: "/tmp", localOS: "15", localShell: "zsh")

    @MainActor
    func testSuggestFlowRedactsQueryAndShowsResults() async {
        StubURLProtocol.stub = .init(body: StubURLProtocol.messageBody(
            json: #"{"commands":[{"command":"ls -la","explanation":"목록","risk":"low"}],"note":""}"#))
        let ai = assistant()
        ai.openPalette(tabID: UUID(), paneID: UUID(), context: context, selection: nil)
        ai.suggest("token=abcd1234 로 로그인하는 법")
        if case .loading = ai.palette?.phase {} else { XCTFail("요청 중 표시") }

        await waitUntil { if case .results = ai.palette?.phase { return true }; return false }
        guard case .results(let query, let suggestions) = ai.palette?.phase else { return XCTFail() }
        XCTAssertEqual(query, "token=abcd1234 로 로그인하는 법")
        XCTAssertEqual(suggestions.commands.map(\.command), ["ls -la"])

        let body = StubURLProtocol.lastBody
        let user = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertFalse(user.contains("abcd1234"), "질문의 토큰도 가린다")
        XCTAssertTrue(user.contains("/tmp"), "현재 폴더를 함께 보낸다")
        XCTAssertEqual(body?["model"] as? String, ai.settings.suggestModel)
    }

    @MainActor
    func testExplainShowsPreviewBeforeSending() async {
        StubURLProtocol.stub = .init(body: StubURLProtocol.messageBody(
            json: #"{"summary":"권한 문제","causes":["키가 등록되지 않음"],"actions":[{"command":"ssh -v web","explanation":"자세히","risk":"low"}],"hostSettingHint":""}"#))
        let ai = assistant()
        ai.explain(.failure(exitCode: 1), output: "$ cat secret\npassword=hunter2\ncat: x: Permission denied",
                   context: context, tabID: UUID(), paneID: UUID())

        XCTAssertEqual(ai.panel?.phase, .preview, "확인 전에는 보내지 않는다")
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        XCTAssertEqual(ai.panel?.maskedCount, 1)
        XCTAssertFalse(ai.panel?.preview.contains("hunter2") ?? true)

        ai.send()
        await waitUntil { if case .answer = ai.panel?.phase { return true }; return false }
        guard case .answer(let answer) = ai.panel?.phase else { return XCTFail() }
        XCTAssertEqual(answer.summary, "권한 문제")
        XCTAssertEqual(answer.actions.first?.command, "ssh -v web")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        let user = ((StubURLProtocol.lastBody?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertFalse(user.contains("hunter2"))
    }

    @MainActor
    func testWithoutConfirmationSendsImmediately() async {
        StubURLProtocol.stub = .init(body: StubURLProtocol.messageBody(
            json: #"{"summary":"요약","causes":[],"actions":[],"hostSettingHint":""}"#))
        let ai = assistant(confirm: false)
        ai.explain(.screen, output: "hello", context: context, tabID: UUID(), paneID: UUID())
        await waitUntil { if case .answer = ai.panel?.phase { return true }; return false }
        XCTAssertEqual(ai.panel?.phase, .answer(AIAnswer(summary: "요약", causes: [], actions: [], hostSettingHint: "")))
    }

    func testEmptyOutputAndMissingKey() async {
        let ai = assistant()
        ai.explain(.screen, output: "  \n ", context: context, tabID: UUID(), paneID: UUID())
        if case .failed = ai.panel?.phase {} else { XCTFail("보낼 내용이 없으면 안내") }

        let noKey = assistant(key: nil, confirm: false)
        noKey.explain(.screen, output: "error", context: context, tabID: UUID(), paneID: UUID())
        await waitUntil { if case .failed = noKey.panel?.phase { return true }; return false }
        guard case .failed(let message) = noKey.panel?.phase else { return XCTFail() }
        XCTAssertTrue(message.contains("Claude API 키"))
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    /// 진단: 저장된 호스트 설정을 보내지만 비밀번호는 보내지 않는다
    func testDiagnosePromptIncludesHostSettingsWithoutPassword() {
        var host = SSHHost()
        host.name = "web"
        host.hostname = "10.0.0.5"
        host.port = 2222
        host.user = "deploy"
        host.authMethod = .password
        let ai = assistant()
        ai.diagnose(output: "Permission denied (publickey,password).", exitCode: 255, host: host,
                    context: AIPaneContext(target: SSHCommand.launch(for: host), directory: nil), tabID: UUID(), paneID: UUID())
        let preview = ai.panel?.preview ?? ""
        XCTAssertTrue(preview.contains("포트: 2222"))
        XCTAssertTrue(preview.contains("사용자: deploy"))
        XCTAssertTrue(preview.contains("인증 방식: 비밀번호"))
        XCTAssertTrue(preview.contains("Permission denied"))
        XCTAssertEqual(ai.panel?.title, "접속 실패 진단 · web")
        XCTAssertTrue(ai.panel?.request.system.contains("exited with code 255") ?? false)
    }

    /// 닫은 뒤 도착한 응답은 버린다
    func testLateResponseAfterCloseIsIgnored() async {
        StubURLProtocol.stub = .init(body: StubURLProtocol.messageBody(
            json: #"{"commands":[],"note":"x"}"#))
        let ai = assistant()
        ai.openPalette(tabID: UUID(), paneID: UUID(), context: context, selection: nil)
        ai.suggest("뭔가")
        ai.closePalette()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(ai.palette)
    }

    /// 설정에서 고른 제공자로 보낸다
    @MainActor
    func testUsesSelectedProvider() async {
        StubURLProtocol.stub = .init(body: try! JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "steps": [["type": "model_output", "content": [["type": "text", "text": #"{"commands":[],"note":"없음"}"#]]]],
        ]))
        let settings = AISettings(defaults: defaults, keyStore: .memory([.gemini: "AIza-test"]))
        settings.provider = .gemini
        let ai = AIAssistant(settings: settings) { provider in
            AIAssistant.defaultClient(provider, session: StubURLProtocol.session, apiKey: { settings.apiKey(provider) })
        }
        XCTAssertEqual(ai.providerName, "Gemini")
        ai.openPalette(tabID: UUID(), paneID: UUID(), context: context, selection: nil)
        ai.suggest("아무거나")
        await waitUntil { if case .results = ai.palette?.phase { return true }; return false }
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(StubURLProtocol.lastBody?["model"] as? String, "gemini-4-carbon")
    }

    func testLongOutputKeepsEnd() {
        let long = String(repeating: "a", count: 20_000) + "END"
        let trimmed = AIAssistant.trimmed(long)
        XCTAssertTrue(trimmed.hasSuffix("END"))
        XCTAssertLessThan(trimmed.count, 12_100)
    }
}

// MARK: - 화면·store 연결

final class AIWorkspaceTests: XCTestCase {
    func testCommandFinishedSetsAndClearsFailure() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let pane = store.currentTab!.panes[0]
        pane.view.onCommandFinished?(2)
        XCTAssertEqual(pane.lastFailedExitCode, 2)
        pane.view.onCommandFinished?(0)
        XCTAssertNil(pane.lastFailedExitCode, "성공하면 버튼을 숨긴다")
        pane.view.onCommandFinished?(nil)
        XCTAssertNil(pane.lastFailedExitCode)
    }

    func testInsertRejectsMultilineCommands() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let pane = store.currentTab!.panes[0]
        store.insertCommand("echo a\nrm -rf /", into: pane.id)
        XCTAssertEqual(store.tabs.count, 1, "여러 줄 명령은 넣지 않는다")
    }

    /// 실제 엔진: 입력줄에 넣은 글자가 화면에 보이고, Enter 없이 실행되지 않는다
    @MainActor
    func testSendTextAppearsOnScreenWithoutRunning() async {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!
        let pane = tab.panes[0]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TerminalTabView(tab: tab).environmentObject(store))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // 셸 프롬프트가 뜰 때까지
        let deadline = Date().addingTimeInterval(8)
        while pane.view.visibleText().isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let marker = "echo myterminal-ai-\(Int.random(in: 1000...9999))"
        store.insertCommand(marker, into: pane.id)
        let shown = Date().addingTimeInterval(5)
        while !pane.view.visibleText().contains(marker) && Date() < shown {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let screen = pane.view.visibleText()
        XCTAssertTrue(screen.contains(marker), "입력줄에 보인다:\n\(screen)")
        let output = marker.replacingOccurrences(of: "echo ", with: "")
        XCTAssertEqual(screen.components(separatedBy: output).count - 1, 1, "실행되지 않았으므로 출력 줄이 없다")
        XCTAssertNil(pane.view.selectedText())
    }

    /// 셸 통합: 실패한 명령의 종료 코드와 현재 폴더가 들어온다 ("왜 실패했나요?" 버튼의 근거)
    @MainActor
    func testShellIntegrationReportsFailedCommandAndDirectory() throws {
        // Ghostty 셸 통합은 zsh·fish·bash 4 이상만 지원한다. macOS 기본 bash(3.2)가 로그인 셸이면(CI 러너 등) 건너뛴다.
        let loginShell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? ""
        guard ["zsh", "fish"].contains((loginShell as NSString).lastPathComponent) else {
            throw XCTSkip("셸 통합을 지원하지 않는 로그인 셸: \(loginShell)")
        }
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!
        let pane = tab.panes[0]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TerminalTabView(tab: tab).environmentObject(store))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func spin(until condition: () -> Bool, timeout: TimeInterval) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }

        spin(until: { pane.pwd != nil }, timeout: 8)
        XCTAssertNotNil(pane.pwd, "셸 통합이 현재 폴더를 알려 준다")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        pane.view.sendText("false")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            if type == .keyDown { pane.view.keyDown(with: event) } else { pane.view.keyUp(with: event) }
        }
        spin(until: { pane.lastFailedExitCode != nil }, timeout: 5)
        XCTAssertEqual(pane.lastFailedExitCode, 1, "false 의 종료 코드")
    }
}

// MARK: - 서버가 바쁠 때 (2026-11-26, 실제 iPad: EXAONE "service is busy, too many concurrent requests(600)" 을 한도 초과로 안내)

final class AIBusyServerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AIHTTP.busyRetryDelays = [0.01, 0.01]
    }

    override func tearDown() {
        AIHTTP.busyRetryDelays = [2, 5]
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func request() -> AIRequest {
        AIRequest(model: "m", system: "sys", user: "질문", schema: AIPrompts.suggestionsSchema)
    }

    /// 바쁘면 잠깐 뒤 다시 보내고, 다시 보내는 중임을 알린다
    func testBusyServerIsRetriedThenSucceeds() async throws {
        StubURLProtocol.queue = [
            .init(status: 529, body: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)),
            .init(body: StubURLProtocol.messageBody(json: #"{"commands":[],"note":"됨"}"#)),
        ]
        final class Box { var values: [AIProgress] = [] }
        let box = Box()
        var request = request()
        request.onProgress = { box.values.append($0) }
        let result = try await ClaudeClient(session: StubURLProtocol.session, apiKey: { "k" }).send(request, as: AISuggestions.self)
        XCTAssertEqual(result.note, "됨")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(box.values, [.retrying(1)])
    }

    /// 사용자 화면 그대로: EXAONE 이 계속 바쁘면 두 번 더 보낸 뒤, 한도가 아니라 서버가 바쁘다고 안내
    func testExaoneBusyIsNotReportedAsQuota() async {
        let busy = StubURLProtocol.Stub(status: 429, body: Data(#"{"result_code":429,"description":"service is busy, too many concurrent requests(600)"}"#.utf8))
        StubURLProtocol.queue = [busy, busy, busy]
        do {
            _ = try await ExaoneClient(session: StubURLProtocol.session, apiKey: { "k" }).send(request(), as: AISuggestions.self)
            XCTFail("실패해야 함")
        } catch {
            let text = error.localizedDescription
            XCTAssertEqual(StubURLProtocol.requestCount, 3, "처음 + 두 번 다시")
            XCTAssertTrue(text.contains("서버가 지금 바빠"), text)
            XCTAssertTrue(text.contains("사용 한도와는 관계없습니다"), text)
            XCTAssertFalse(text.contains("사용 한도를 넘었습니다"), text)
            XCTAssertTrue(text.contains("service is busy"), "서버 메시지는 그대로 붙인다")
        }
    }

    /// 진짜 한도 초과는 다시 보내도 같으므로 바로 알린다 (예전 안내 그대로)
    func testQuotaLimitIsNotRetried() async {
        StubURLProtocol.stub = .init(status: 429, body: Data(#"{"error":{"message":"You exceeded your current quota"}}"#.utf8))
        do {
            _ = try await OpenAIClient(session: StubURLProtocol.session, apiKey: { "k" }).send(request(), as: AISuggestions.self)
            XCTFail("실패해야 함")
        } catch {
            XCTAssertEqual(StubURLProtocol.requestCount, 1)
            XCTAssertTrue(error.localizedDescription.contains("사용 한도를 넘었습니다"), error.localizedDescription)
        }
    }

    func testBusyDetection() {
        XCTAssertTrue(AIHTTP.isBusy(status: 503, message: nil))
        XCTAssertTrue(AIHTTP.isBusy(status: 529, message: "Overloaded"))
        XCTAssertTrue(AIHTTP.isBusy(status: 429, message: "service is busy, too many concurrent requests(600)"))
        XCTAssertFalse(AIHTTP.isBusy(status: 429, message: "Rate limit exceeded: quota"))
        XCTAssertFalse(AIHTTP.isBusy(status: 429, message: nil))
        XCTAssertFalse(AIHTTP.isBusy(status: 500, message: "busy"))
    }
}
