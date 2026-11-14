import Foundation

/// AI 기능의 화면 상태: ⌘K 명령 추천 팔레트, 설명·진단 패널.
/// 메인 스레드에서 쓰고, 네트워크 요청만 백그라운드 작업으로 돌린다.
final class AIAssistant: ObservableObject {
    let settings: AISettings
    /// 제공자에 맞는 클라이언트 (테스트에서는 네트워크 대역을 넣는다)
    var makeClient: (AIProvider) -> AIClient

    init(settings: AISettings = .shared, makeClient: ((AIProvider) -> AIClient)? = nil) {
        self.settings = settings
        self.makeClient = makeClient ?? { [weak settings] provider in
            AIAssistant.defaultClient(provider, apiKey: { settings?.apiKey(provider) })
        }
    }

    static func defaultClient(_ provider: AIProvider, session: URLSession = .shared, apiKey: @escaping () -> String?) -> AIClient {
        switch provider {
        case .anthropic: ClaudeClient(session: session, apiKey: apiKey)
        case .openai: OpenAIClient(session: session, apiKey: apiKey)
        case .gemini: GeminiClient(session: session, apiKey: apiKey)
        }
    }

    /// 지금 쓰는 제공자 이름 (화면 문구)
    var providerName: String { settings.provider.shortName }

    // MARK: ⌘K 명령 추천

    struct Palette: Identifiable {
        let id = UUID()
        let tabID: UUID
        let paneID: UUID
        let context: AIPaneContext
        /// 팔레트를 열 때 화면에서 선택되어 있던 글자 ("선택한 내용 설명" 항목용)
        let selection: String?
        var phase: PalettePhase = .input
    }

    enum PalettePhase: Equatable {
        case input
        case loading(query: String)
        case results(query: String, AISuggestions)
        case failed(query: String, String)
    }

    @Published var palette: Palette?
    private var paletteTask: Task<Void, Never>?

    func openPalette(tabID: UUID, paneID: UUID, context: AIPaneContext, selection: String?) {
        closePalette()
        palette = Palette(tabID: tabID, paneID: paneID, context: context, selection: selection)
    }

    func closePalette() {
        paletteTask?.cancel()
        paletteTask = nil
        palette = nil
    }

    func suggest(_ query: String) {
        guard let current = palette else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let prompt = AIPrompts.suggest(query: SecretRedactor.redact(trimmed).text, context: current.context)
        let request = AIRequest(
            model: settings.suggestModel, system: prompt.system, user: prompt.user,
            schema: AIPrompts.suggestionsSchema, effort: "low", maxTokens: 8000)

        palette?.phase = .loading(query: trimmed)
        paletteTask?.cancel()
        let client = makeClient(settings.provider)
        paletteTask = Task { [weak self] in
            let phase: PalettePhase
            do {
                phase = .results(query: trimmed, try await client.send(request, as: AISuggestions.self))
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(query: trimmed, error.localizedDescription)
            }
            await MainActor.run {
                guard let self, self.palette?.id == current.id else { return }
                self.palette?.phase = phase
            }
        }
    }

    // MARK: 설명·진단 패널

    enum PanelKind: Equatable {
        case explain(AIPrompts.ExplainKind)
        case diagnose(exitCode: Int32)
    }

    struct Panel: Identifiable {
        let id = UUID()
        let tabID: UUID
        let paneID: UUID
        let kind: PanelKind
        let title: String
        /// 보낼 터미널 내용 (가린 뒤)
        let preview: String
        /// 가린 개수
        let maskedCount: Int
        let request: AIRequest
        var phase: PanelPhase
    }

    enum PanelPhase: Equatable {
        case preview
        case loading
        case answer(AIAnswer)
        case failed(String)
    }

    @Published var panel: Panel?
    private var panelTask: Task<Void, Never>?

    /// 화면 내용을 설명한다. 확인 설정이 켜져 있으면 보낼 내용을 먼저 보여 준다.
    func explain(_ kind: AIPrompts.ExplainKind, output: String, context: AIPaneContext, tabID: UUID, paneID: UUID) {
        let title: String
        switch kind {
        case .selection: title = "선택한 내용 설명"
        case .failure(let code): title = "왜 실패했나요? (종료 코드 \(code))"
        case .screen: title = "화면 내용 설명"
        }
        let masked = SecretRedactor.redact(Self.trimmed(output))
        let prompt = AIPrompts.explain(kind, output: masked.text, context: context)
        open(Panel(
            tabID: tabID, paneID: paneID, kind: .explain(kind), title: title,
            preview: masked.text, maskedCount: masked.count,
            request: AIRequest(
                model: settings.model, system: prompt.system, user: prompt.user, schema: AIPrompts.answerSchema),
            phase: .preview))
    }

    /// SSH 접속 실패를 진단한다.
    func diagnose(output: String, exitCode: Int32, host: SSHHost?, context: AIPaneContext, tabID: UUID, paneID: UUID) {
        let masked = SecretRedactor.redact(Self.trimmed(output))
        let prompt = AIPrompts.diagnose(output: masked.text, exitCode: exitCode, host: host, context: context)
        let maskedPrompt = SecretRedactor.redact(prompt.user)
        open(Panel(
            tabID: tabID, paneID: paneID, kind: .diagnose(exitCode: exitCode),
            title: "접속 실패 진단 · \(context.host ?? "서버")",
            preview: maskedPrompt.text, maskedCount: masked.count + maskedPrompt.count,
            request: AIRequest(
                model: settings.model, system: prompt.system, user: maskedPrompt.text, schema: AIPrompts.answerSchema),
            phase: .preview))
    }

    private func open(_ newPanel: Panel) {
        closePanel()
        guard !newPanel.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            var empty = newPanel
            empty.phase = .failed("보낼 내용이 없습니다. 화면에 글자가 있는지 확인해 주세요.")
            panel = empty
            return
        }
        panel = newPanel
        if !settings.confirmBeforeSend { send() }
    }

    /// 미리 보기에서 "보내기" (또는 다시 시도)
    func send() {
        guard let current = panel else { return }
        panel?.phase = .loading
        panelTask?.cancel()
        // 미리 보기 뒤에 설정에서 제공자를 바꿨을 수 있으므로 보낼 때의 제공자·모델을 쓴다
        var request = current.request
        request.model = settings.model
        let client = makeClient(settings.provider)
        panelTask = Task { [weak self] in
            let phase: PanelPhase
            do {
                phase = .answer(try await client.send(request, as: AIAnswer.self))
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(error.localizedDescription)
            }
            await MainActor.run {
                guard let self, self.panel?.id == current.id else { return }
                self.panel?.phase = phase
            }
        }
    }

    func closePanel() {
        panelTask?.cancel()
        panelTask = nil
        panel = nil
    }

    /// 보낼 화면 내용 길이 제한 (뒤쪽이 최근 출력이므로 뒤를 남긴다)
    static let maxOutputCharacters = 12_000

    static func trimmed(_ output: String) -> String {
        guard output.count > maxOutputCharacters else { return output }
        return "…(앞부분 생략)\n" + output.suffix(maxOutputCharacters)
    }
}
