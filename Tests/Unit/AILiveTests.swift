import XCTest
@testable import MyTerminal

/// 실제 AI 제공자에 보내 보는 시험 (키가 있을 때만, 요청 비용이 든다).
///   TEST_RUNNER_MT_EXAONE_KEY=<키> xcodebuild ... test -only-testing:MyTerminalTests/AILiveTests
/// 키는 환경 변수로만 넘기고 어디에도 저장하지 않는다.
final class AILiveTests: XCTestCase {
    /// EXAONE 이 바쁠 때(거절이 연달아 오는 때)도 다시 보내기로 결국 답을 받는다 (2026-11-26 iPad 판 사용자 확인 중 발견)
    func testExaoneSuggestEventuallyAnswers() async throws {
        let key = try XCTUnwrap(ProcessInfo.processInfo.environment["MT_EXAONE_KEY"].flatMap { $0.isEmpty ? nil : $0 },
                                "MT_EXAONE_KEY 없음")
        let prompt = AIPrompts.suggest(query: "nginx 기본 설정 디렉터리", context: AIPaneContext(target: nil, directory: nil))
        var request = AIRequest(model: AIProvider.exaone.defaultModel, system: prompt.system, user: prompt.user,
                                schema: AIPrompts.suggestionsSchema, effort: "low", maxTokens: 8000)
        final class Box: @unchecked Sendable { var retries = 0 }
        let box = Box()
        request.onProgress = { if case .retrying(let n) = $0 { box.retries = n } }
        let started = Date()
        let result = try await ExaoneClient(apiKey: { key }).send(request, as: AISuggestions.self)
        print("EXAONE 답: \(result.commands.map(\.command)) · 다시 보낸 횟수 \(box.retries) · \(Int(Date().timeIntervalSince(started)))초")
        XCTAssertFalse(result.commands.isEmpty && result.note.isEmpty)
    }

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MT_EXAONE_KEY"] == nil, "MT_EXAONE_KEY 없음 (실제 요청 시험)")
    }
}
