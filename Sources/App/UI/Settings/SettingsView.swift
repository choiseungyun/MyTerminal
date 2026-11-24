import AppKit
import SwiftUI

/// 설정 창 (⌘,)
struct SettingsView: View {
    var body: some View {
        TabView {
            TerminalSettingsPane()
                .tabItem { Label("터미널", systemImage: "terminal") }
            ThemeSettingsPane()
                .tabItem { Label("테마", systemImage: "paintpalette") }
            AISettingsPane()
                .tabItem { Label("AI", systemImage: "sparkles") }
            UpdateSettingsPane()
                .tabItem { Label("업데이트", systemImage: "arrow.down.circle") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - 업데이트

private struct UpdateSettingsPane: View {
    @ObservedObject private var updater = AppUpdater.shared

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Form {
            Section {
                LabeledContent("지금 버전", value: AppUpdater.currentVersion)
                LabeledContent("마지막 확인", value: updater.lastCheck.map { Self.dateFormatter.string(from: $0) } ?? "아직 없음")
                Button("지금 업데이트 확인") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            Section {
                Toggle("자동으로 업데이트 확인 (하루에 한 번)", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                Toggle("새 버전을 미리 받아 두고 앱을 끝낼 때 설치", isOn: Binding(
                    get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                    .disabled(!updater.automaticallyChecks)
            } footer: {
                Text(updater.isAvailable
                     ? "GitHub 릴리스에서 새 버전을 확인합니다. 받은 파일은 서명을 확인한 뒤에만 설치하며, 사용 환경 정보는 보내지 않습니다."
                     : "개발 빌드에서는 자동 업데이트를 쓰지 않습니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!updater.isAvailable)
    }
}

// MARK: - AI

private struct AISettingsPane: View {
    @ObservedObject private var settings = AISettings.shared
    @State private var keyInput = ""

    private var provider: AIProvider { settings.provider }

    var body: some View {
        Form {
            Section {
                Picker("AI 제공자", selection: $settings.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.title + (settings.hasKey(provider) ? "  ✓" : "")).tag(provider)
                    }
                }
            } footer: {
                Text("✓ 는 키가 저장된 제공자입니다. 제공자마다 키와 모델을 따로 기억합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.hasKey(provider) {
                    HStack {
                        Label("저장됨 (키체인)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("삭제", role: .destructive) { settings.deleteAPIKey(for: provider) }
                    }
                }
                HStack {
                    SecureField(settings.hasKey(provider) ? "새 키로 바꾸기" : provider.keyPlaceholder, text: $keyInput)
                    Button("저장") {
                        settings.saveAPIKey(keyInput, for: provider)
                        keyInput = ""
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("\(provider.shortName) API 키")
            } footer: {
                Text("\(provider.keyConsole) 에서 만든 키를 넣으세요. 키는 이 Mac 의 키체인에만 저장되고, 요청 비용은 이 키의 계정에 청구됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("모델") {
                ModelPicker(title: "설명·진단", provider: provider, purpose: .explain, settings: settings)
                ModelPicker(title: "명령 추천 (⌘K)", provider: provider, purpose: .suggest, settings: settings)
            }

            Section {
                Toggle("화면 내용을 보내기 전에 보낼 내용 확인", isOn: $settings.confirmBeforeSend)
            } header: {
                Text("개인 정보")
            } footer: {
                Text("선택한 내용·화면 설명과 접속 실패 진단은 터미널에 보이는 글자를 고른 AI 제공자에 보냅니다. 비밀번호·토큰처럼 보이는 문자열은 [가림] 으로 바꾸지만 모두 찾지는 못할 수 있습니다. 저장된 비밀번호는 보내지 않습니다. ChatGPT·Gemini 는 요청을 서버에 저장하지 않도록(store: false) 보냅니다. EXAONE 은 저장 여부를 고르는 옵션이 없습니다. AI 가 제안한 명령은 입력줄에만 들어가고 자동으로 실행되지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.provider) { keyInput = "" }
    }
}

/// 모델 고르기: 목록 + 직접 입력
private struct ModelPicker: View {
    let title: String
    let provider: AIProvider
    let purpose: AISettings.Purpose
    @ObservedObject var settings: AISettings
    @State private var custom = ""

    private static let customTag = "__custom__"

    private var current: String { settings.model(for: provider, purpose) }

    var body: some View {
        Picker(title, selection: Binding(
            get: { provider.isPreset(current) ? current : Self.customTag },
            set: { value in
                if value == Self.customTag {
                    custom = provider.isPreset(current) ? "" : current
                    if !custom.isEmpty { settings.setModel(custom, for: provider, purpose) }
                } else {
                    settings.setModel(value, for: provider, purpose)
                }
            })) {
            ForEach(provider.presets, id: \.id) { Text($0.title).tag($0.id) }
            Divider()
            Text("직접 입력…").tag(Self.customTag)
        }
        if !provider.isPreset(current) || !custom.isEmpty {
            HStack {
                TextField("모델 ID (예: \(provider.defaultModel))", text: $custom)
                    .onSubmit { settings.setModel(custom, for: provider, purpose) }
                Button("적용") { settings.setModel(custom, for: provider, purpose) }
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onAppear { if custom.isEmpty, !provider.isPreset(current) { custom = current } }
        }
    }
}

// MARK: - 터미널

private struct TerminalSettingsPane: View {
    @ObservedObject private var settings = TerminalSettings.shared

    /// 고정폭 글꼴 가족 이름
    private static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }()

    var body: some View {
        Form {
            Section("글꼴") {
                Picker("글꼴", selection: $settings.fontFamily) {
                    Text("기본 (JetBrains Mono)").tag("")
                    Divider()
                    ForEach(Self.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Text("크기")
                    Spacer()
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("", value: $settings.fontSize, in: TerminalSettings.fontSizeRange, step: 1)
                        .labelsHidden()
                }
                FontPreview(family: settings.fontFamily, size: settings.fontSize, theme: settings.theme)
            }

            Section("커서") {
                Picker("모양", selection: $settings.cursorStyle) {
                    ForEach(TerminalSettings.CursorStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("깜박임", isOn: $settings.cursorBlink)
            }

            Section {
                Picker("Option 키를 Alt(Meta)로 사용", selection: $settings.optionAsAlt) {
                    ForEach(TerminalSettings.OptionAsAlt.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } header: {
                Text("키보드")
            } footer: {
                Text("켜면 Option+B, Option+F 같은 단축키가 셸·Emacs 에서 단어 이동으로 동작합니다. 대신 해당 Option 키로 특수 문자(∫, ƒ 등)를 입력할 수 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("고급") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Ghostty 전용 terminfo 사용 (TERM=xterm-ghostty)", isOn: $settings.useGhosttyTerminfo)
                    Text("끄면 TERM=xterm-256color 를 씁니다 (기본, 권장). 켜면 일부 확장 기능을 쓸 수 있지만 top 같은 root 권한 프로그램과 sudo 에서 \"Error opening terminal\" 이 날 수 있습니다. 새로 여는 터미널부터 적용됩니다. SSH 접속은 항상 xterm-256color 입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("설정 파일 직접 편집")
                        Text("Ghostty 설정 형식. 이 화면의 값보다 우선합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("terminal.conf 열기", action: openUserConfig)
                }
                HStack {
                    Spacer()
                    Button("기본값으로 되돌리기") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// terminal.conf 가 없으면 안내 주석과 함께 만들고 기본 편집기로 연다.
    private func openUserConfig() {
        guard let url = GhosttyRuntime.userConfigURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = """
            # MyTerminal 사용자 설정 (Ghostty 설정 형식)
            # 이 파일의 값은 설정 화면보다 우선합니다. 저장 후 설정 화면에서 아무 값이나 바꾸거나 앱을 다시 열면 반영됩니다.
            # 설정 키 목록: https://ghostty.org/docs/config/reference
            #
            # 예)
            # font-feature = -calt
            # window-padding-x = 16

            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}

private struct FontPreview: View {
    let family: String
    let size: Double
    /// 빈 문자열 = MyTerminal 기본 색 (앱 모양을 따름)
    let theme: String

    var body: some View {
        let font: Font = family.isEmpty
            ? .system(size: size, design: .monospaced)
            : .custom(family, size: size)
        let preview = theme.isEmpty ? nil : ThemeCatalog.preview(theme)
        Text("deploy@web-01:~$ ls -la  가나다 0O1lI")
            .font(font)
            .foregroundStyle(preview?.foreground ?? Theme.terminalForeground)
            .lineLimit(1)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(preview?.background ?? Theme.terminalBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider))
    }
}

// MARK: - 테마

private struct ThemeSettingsPane: View {
    @ObservedObject private var settings = TerminalSettings.shared
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var query = ""

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ThemeCatalog.names }
        return ThemeCatalog.names.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("앱 모양").font(.headline)
                    Text("창·메뉴·설정 화면의 밝기. 시스템은 macOS 설정을 따릅니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("앱 모양", selection: $appearance.mode) {
                    ForEach(AppearanceSettings.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            HStack {
                Text("터미널 색").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("테마 검색 (\(ThemeCatalog.names.count)개)", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)

            Divider()

            ScrollViewReader { proxy in
                List {
                    ThemeRow(
                        name: "MyTerminal 기본 (앱 모양을 따름)",
                        preview: .init(
                            background: Theme.terminalBackground,
                            foreground: Theme.terminalForeground,
                            palette: []),
                        isSelected: settings.theme.isEmpty
                    ) { settings.theme = "" }
                    .id("")

                    ForEach(filtered, id: \.self) { name in
                        ThemeRow(
                            name: name,
                            preview: ThemeCatalog.preview(name),
                            isSelected: settings.theme == name
                        ) { settings.theme = name }
                        .id(name)
                    }
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(settings.theme, anchor: .center) }
            }

            Divider()
            Text("터미널 색은 Ghostty 에 포함된 테마 모음입니다. 고르면 열려 있는 터미널에 바로 적용됩니다. MyTerminal 기본은 앱 모양에 맞춰 밝은·어두운 색으로 바뀝니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }
}

private struct ThemeRow: View {
    let name: String
    let preview: ThemeCatalog.Preview?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 미리보기: 배경 위에 글자색 "Aa" 와 기본 8색
                HStack(spacing: 3) {
                    Text("Aa")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(preview?.foreground ?? .primary)
                    ForEach(Array((preview?.palette ?? []).enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 7, height: 7)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 132, height: 22, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(preview?.background ?? .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.divider))

                Text(name).lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
