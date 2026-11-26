import AppKit
import SwiftUI

/// 터미널 탭 위에 띄우는 AI 화면들 (이 탭의 것만)
struct AIOverlays: View {
    @ObservedObject var ai: AIAssistant
    let tabID: UUID

    var body: some View {
        ZStack {
            if let panel = ai.panel, panel.tabID == tabID {
                AIResultPanel(ai: ai, settings: ai.settings, panel: panel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(14)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let palette = ai.palette, palette.tabID == tabID {
                AICommandPalette(ai: ai, settings: ai.settings, palette: palette)
                    .id(palette.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 36)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: ai.palette?.id)
        .animation(.easeOut(duration: 0.15), value: ai.panel?.id)
    }
}

// MARK: - ⌘K 명령 추천

private struct AICommandPalette: View {
    @ObservedObject var ai: AIAssistant
    @ObservedObject var settings: AISettings
    let palette: AIAssistant.Palette
    @EnvironmentObject private var store: WorkspaceStore

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: AISuggestions? {
        if case .results(_, let suggestions) = palette.phase { return suggestions }
        return nil
    }
    /// 결과가 지금 입력한 질문에 대한 것인지 (질문을 고치면 Enter 가 다시 묻기)
    private var resultsAreCurrent: Bool {
        if case .results(let asked, _) = palette.phase { return asked == query.trimmingCharacters(in: .whitespacesAndNewlines) }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            field
            content
            Text(resultsAreCurrent
                 ? "↑↓ 고르고 Enter: 입력줄에 넣기 (실행하지 않음) · Esc 닫기"
                 : "Enter: 추천 받기 · Esc 닫기 · 결과는 입력줄에만 들어가고 실행되지 않습니다")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .frame(width: 620)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text("AI 명령 추천").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            ProviderChip(provider: settings.provider, model: settings.suggestModel)
            Label(palette.context.label, systemImage: palette.context.isRemote ? "server.rack" : "terminal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.selection))
            Spacer()
            Button { close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("닫기 (Esc)")
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble").foregroundStyle(Theme.textTertiary)
            TextField("무엇을 하고 싶은지 입력하세요 (예: 용량 큰 폴더 찾기, nginx 설정 검사)", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
    }

    @ViewBuilder
    private var content: some View {
        if !settings.hasAPIKey {
            AIKeyMissingView(provider: settings.provider)
        } else {
            switch palette.phase {
            case .input:
                quickActions
            case .loading:
                AIWaitingRow(provider: settings.provider, waiting: palette.waiting, idleText: "명령을 찾는 중…")
                    .padding(.vertical, 6)
            case .results(_, let suggestions):
                if suggestions.commands.isEmpty {
                    Text(suggestions.note.isEmpty ? "추천할 명령이 없습니다." : suggestions.note)
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(suggestions.commands.enumerated()), id: \.offset) { index, command in
                            AICommandRow(command: command, selected: index == selection) {
                                insert(command)
                            }
                            .onTapGesture { selection = index }
                        }
                    }
                    if !suggestions.note.isEmpty {
                        Text(suggestions.note).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
            case .failed(_, let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xE8964A))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                AISettingsButton()
            }
        }
    }

    /// 아무것도 묻기 전: 선택한 내용·화면 설명 바로 가기
    @ViewBuilder
    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let selected = palette.selection {
                quickAction("선택한 내용 설명", detail: "\(selected.split(separator: "\n").count)줄 선택됨", symbol: "text.magnifyingglass")
            } else {
                quickAction("지금 화면 설명", detail: "보이는 출력에서 오류·원인 찾기", symbol: "rectangle.and.text.magnifyingglass")
            }
        }
    }

    private func quickAction(_ title: String, detail: String, symbol: String) -> some View {
        Button {
            ai.closePalette()
            store.explainWithAI()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.accent)
                Text(title).foregroundStyle(Theme.textPrimary)
                Text(detail).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("⇧⌘E").foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.selection.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        if resultsAreCurrent, let commands = results?.commands, commands.indices.contains(selection) {
            insert(commands[selection])
        } else {
            selection = 0
            ai.suggest(query)
        }
    }

    private func move(_ delta: Int) {
        guard let count = results?.commands.count, count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func insert(_ command: AICommand) {
        guard command.canInsert else { return }
        let paneID = palette.paneID
        ai.closePalette()
        store.insertCommand(command.command, into: paneID)
    }

    private func close() {
        let paneID = palette.paneID
        ai.closePalette()
        store.focus(paneID)
    }
}

/// 명령 한 줄: 명령, 설명, 위험도, [입력] [복사]
private struct AICommandRow: View {
    let command: AICommand
    let selected: Bool
    let onInsert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                if !command.command.isEmpty {
                    RiskBadge(risk: command.effectiveRisk)
                    Text(command.command)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if !command.command.isEmpty {
                    if command.canInsert {
                        Button("입력", action: onInsert)
                            .controlSize(.small)
                            .help("입력줄에 넣습니다. 실행은 직접 Enter 를 눌러야 합니다.")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command.command, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .controlSize(.small)
                        .help("복사")
                }
            }
            Text(command.explanation)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = command.warning {
                Label(warning, systemImage: "exclamationmark.octagon.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0xE2668F))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selection : Theme.field.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

private struct RiskBadge: View {
    let risk: AIRisk

    private var color: Color {
        switch risk {
        case .low: Color(hex: 0x3FB98A)
        case .medium: Color(hex: 0xD6B744)
        case .high: Color(hex: 0xE2668F)
        }
    }

    var body: some View {
        Text(risk.title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}

/// 답을 기다리는 줄: 단계(생각 중·답 쓰는 중)와 경과 시간
private struct AIWaitingRow: View {
    let provider: AIProvider
    let waiting: AIWaiting?
    /// 단계를 모를 때 문구 ("명령을 찾는 중…")
    let idleText: String

    private var text: String {
        switch waiting?.progress {
        case .thinking: "\(provider.subject) 생각하는 중…"
        case .answering: "\(provider.subject) 답을 쓰는 중…"
        case .retrying(let attempt): "\(provider.shortName) 서버가 바빠 다시 보내는 중… (\(attempt)번째)"
        case nil: "\(provider.subject) \(idleText)"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if let started = waiting?.started {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                    HStack(spacing: 6) {
                        Text("\(seconds)초").monospacedDigit()
                        if seconds >= 15 { Text("· 생각이 길면 1분 넘게 걸릴 수 있습니다") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

/// 지금 쓰는 AI 제공자 표시 (마우스를 올리면 모델 이름)
private struct ProviderChip: View {
    let provider: AIProvider
    let model: String

    var body: some View {
        Text(provider.shortName)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.accent.opacity(0.15)))
            .help("\(provider.title) · \(model) (설정 > AI 에서 변경)")
    }
}

/// 설정 > AI 를 여는 버튼 (오류가 났을 때 제공자·모델·키를 바꾸러 가기)
private struct AISettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("AI 설정 열기") { openSettings() }
    }
}

/// API 키가 없을 때 안내
private struct AIKeyMissingView: View {
    let provider: AIProvider
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(Color(hex: 0xD6B744))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(provider.shortName) API 키가 필요합니다").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("설정 > AI 에서 제공자를 고르고 키를 넣으세요. 키는 이 Mac 의 키체인에만 저장됩니다.").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("설정 열기") { openSettings() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field.opacity(0.6)))
    }
}

// MARK: - 설명·진단 패널

private struct AIResultPanel: View {
    @ObservedObject var ai: AIAssistant
    @ObservedObject var settings: AISettings
    let panel: AIAssistant.Panel
    @EnvironmentObject private var store: WorkspaceStore

    private var isDiagnosis: Bool {
        if case .diagnose = panel.kind { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text(panel.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                ProviderChip(provider: settings.provider, model: settings.model)
                Button { ai.closePanel() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .keyboardShortcut(.cancelAction)
                    .help("닫기 (Esc)")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 500)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
    }

    @ViewBuilder
    private var content: some View {
        if !settings.hasAPIKey {
            AIKeyMissingView(provider: settings.provider)
        }
        switch panel.phase {
        case .preview:
            preview
        case .loading:
            AIWaitingRow(provider: settings.provider, waiting: panel.waiting, idleText: "살펴보는 중…")
        case .answer(let answer):
            answerView(answer)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xE8964A))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !panel.preview.isEmpty {
                    Button("다시 시도") { ai.send() }.disabled(!settings.hasAPIKey)
                }
                AISettingsButton()
            }
        }
    }

    /// 보낼 내용 미리 보기
    @ViewBuilder
    private var preview: some View {
        Text("아래 내용을 \(settings.provider.shortName)에 보냅니다.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        if panel.maskedCount > 0 {
            Label("비밀번호·토큰으로 보이는 \(panel.maskedCount)곳을 [가림] 으로 바꿨습니다.", systemImage: "eye.slash")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        ScrollView {
            Text(panel.preview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 200)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.terminalBackground))
        HStack {
            Toggle("다음부터 묻지 않고 보내기", isOn: Binding(
                get: { !settings.confirmBeforeSend }, set: { settings.confirmBeforeSend = !$0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            Button("취소") { ai.closePanel() }
            Button("보내기") { ai.send() }
                .keyboardShortcut(.defaultAction)
                .disabled(!settings.hasAPIKey)
        }
    }

    @ViewBuilder
    private func answerView(_ answer: AIAnswer) -> some View {
        Text(answer.summary)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

        if !answer.causes.isEmpty {
            section("원인")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(answer.causes.enumerated()), id: \.offset) { index, cause in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).").foregroundStyle(Theme.textTertiary)
                        Text(cause).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                }
            }
        }

        if !answer.hostSettingHint.isEmpty {
            Label {
                Text(answer.hostSettingHint).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "slider.horizontal.3")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textPrimary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.15)))
        }

        if !answer.actions.isEmpty {
            section(isDiagnosis ? "해결 방법 (명령은 이 Mac 의 새 터미널에 입력됩니다)" : "해결 방법")
            VStack(spacing: 6) {
                ForEach(answer.actions) { action in
                    AICommandRow(command: action, selected: false) {
                        store.insertCommand(action.command, into: panel.paneID)
                    }
                }
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }
}
