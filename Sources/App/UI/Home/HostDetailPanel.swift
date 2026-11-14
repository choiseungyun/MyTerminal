import AppKit
import SwiftUI

/// 호스트 화면 오른쪽에 밀려 나오는 호스트 정보·편집 패널.
///
/// - 기존 호스트: 고치는 즉시 자동 저장(0.4초 뒤), 아래 "연결" 버튼
/// - 새 호스트: 아래 "추가" 버튼으로 저장하면 같은 패널이 기존 호스트 편집으로 바뀐다
struct HostDetailPanel: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var store: WorkspaceStore

    let isNew: Bool
    let onClose: () -> Void
    /// 새 호스트를 추가했을 때 (패널을 편집 모드로 바꾸기 위해)
    let onCreated: (UUID) -> Void
    /// 복제한 호스트를 새 호스트로 열 때
    let onDuplicate: (SSHHost) -> Void

    @State private var form: HostForm
    @State private var password = ""
    @State private var savedPassword = ""
    @State private var hasSavedPassword: Bool
    @State private var saveTask: Task<Void, Never>?
    @State private var savedAt: Date?
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    static let width: CGFloat = 380

    init(
        host: SSHHost,
        isNew: Bool,
        onClose: @escaping () -> Void,
        onCreated: @escaping (UUID) -> Void,
        onDuplicate: @escaping (SSHHost) -> Void
    ) {
        self.isNew = isNew
        self.onClose = onClose
        self.onCreated = onCreated
        self.onDuplicate = onDuplicate
        _form = State(initialValue: HostForm(host: host))
        _hasSavedPassword = State(initialValue: !isNew && Keychain.hasPassword(hostID: host.id))
    }

    private var host: SSHHost { form.host }
    private var fromSSHConfig: Bool { host.isFromSSHConfig }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let alias = host.sshConfigAlias { sshConfigNotice(alias) }
                    addressSection
                    generalSection
                    sshSection
                    notesSection
                    if let message = form.validationError?.message ?? errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
            }

            footer
        }
        .frame(width: Self.width)
        .background(Theme.sidebarBackground)
        .onChange(of: form) { _, _ in scheduleSave() }
        .onChange(of: password) { _, _ in scheduleSave() }
        .onDisappear(perform: flushSave)
        .onExitCommand(perform: close)
        .confirmationDialog("\"\(host.displayName)\" 을(를) 삭제할까요?", isPresented: $confirmDelete) {
            Button("삭제", role: .destructive, action: delete)
        } message: {
            Text("저장된 비밀번호도 함께 지워집니다.")
        }
    }

    // MARK: - 머리글

    private var header: some View {
        HStack(spacing: 10) {
            Text(isNew ? "새 호스트" : "호스트 정보")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if savedAt != nil {
                Text("저장됨")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .transition(.opacity)
            }
            Spacer()
            if !isNew {
                Menu {
                    Button("새 탭에서 연결", action: connect)
                    Button("연결하고 파일 보기 (SFTP)") {
                        saveTask?.cancel()
                        if let host = saveNow() { store.connect(host, showFiles: true) }
                    }
                    Button("SFTP 탭에서 열기") {
                        saveTask?.cancel()
                        if let host = saveNow() { store.openSFTP(host) }
                    }
                    if store.hasTerminalTab {
                        Button("분할 화면으로 연결") { if let host = saveNow() { store.connectInSplit(host) } }
                    }
                    Divider()
                    Button("복제") { if let host = saveNow() { onDuplicate(host) } }
                    Button("ssh 명령 복사") {
                        guard let host = try? form.build() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SSHCommand.launch(for: host).displayCommand, forType: .string)
                    }
                    Divider()
                    Button("삭제…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("더 보기")
            }
            Button(action: close) {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("패널 닫기 (esc)")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: - 섹션

    private func sshConfigNotice(_ alias: String) -> some View {
        PanelSection {
            VStack(alignment: .leading, spacing: 8) {
                Label("~/.ssh/config 의 \"\(alias)\"", systemImage: "doc.text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("접속할 때 ssh 설정을 그대로 따르므로 주소·포트·사용자·키는 ~/.ssh/config 에서 바꿉니다.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("직접 설정으로 전환") { form.host.sshConfigAlias = nil }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
    }

    private var addressSection: some View {
        PanelSection(title: "주소") {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.hostIcon)
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: "server.rack").foregroundStyle(.white))
                PanelField(icon: nil, placeholder: "호스트 이름 또는 IP", text: $form.host.hostname)
                    .disabled(fromSSHConfig)
            }
        }
    }

    private var generalSection: some View {
        PanelSection(title: "일반") {
            PanelField(icon: "character.cursor.ibeam", placeholder: "이름 (비우면 주소)", text: $form.host.name)
            HStack(spacing: 6) {
                PanelField(icon: "folder", placeholder: "그룹", text: optional($form.host.group))
                if !hostStore.groups.isEmpty {
                    Menu {
                        ForEach(hostStore.groups, id: \.self) { group in
                            Button(group) { form.host.group = group }
                        }
                        Divider()
                        Button("그룹 없음") { form.host.group = nil }
                    } label: {
                        Image(systemName: "chevron.down").foregroundStyle(Theme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("기존 그룹에서 고르기")
                }
            }
            PanelField(icon: "tag", placeholder: "태그 (쉼표로 구분)", text: $form.tagsText)
        }
    }

    private var sshSection: some View {
        PanelSection(title: "SSH") {
            HStack(spacing: 8) {
                PanelField(icon: "person", placeholder: "사용자", text: optional($form.host.user))
                PanelField(icon: nil, placeholder: "포트 22", text: $form.portText)
                    .frame(width: 96)
            }
            .disabled(fromSSHConfig)

            Picker("", selection: $form.host.authMethod) {
                ForEach(SSHHost.AuthMethod.allCases) { method in
                    Text(method == .auto ? "키 · 에이전트" : "비밀번호").tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if host.authMethod == .password {
                PanelSecureField(
                    placeholder: hasSavedPassword ? "비밀번호 저장됨 (바꾸려면 입력)" : "비밀번호 (Keychain 에 저장)",
                    text: $password)
                if hasSavedPassword {
                    Button("저장된 비밀번호 지우기", role: .destructive) {
                        Keychain.deletePassword(hostID: host.id)
                        hasSavedPassword = false
                        password = ""
                        savedPassword = ""
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
            } else {
                HStack(spacing: 6) {
                    PanelField(icon: "key", placeholder: "키 파일 (비우면 기본 키·에이전트)", text: optional($form.host.identityFile))
                    Button("찾기…", action: chooseKeyFile)
                        .controlSize(.small)
                }
                .disabled(fromSSHConfig)
            }

            jumpHostRow
                .disabled(fromSSHConfig)

            PanelField(icon: "terminal", placeholder: "접속 후 실행할 명령 (선택)", text: optional($form.host.remoteCommand))
            if host.remoteCommand?.isEmpty == false {
                Text("접속하면 서버에서 이 명령을 실행합니다. 파일 패널(SFTP)은 이 서버 자체의 파일을 보여 줍니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 경유 서버: 저장된 호스트를 고르거나(키·포트 적용) user@host:port 를 직접 쓴다.
    @ViewBuilder
    private var jumpHostRow: some View {
        let candidates = hostStore.hosts.filter { $0.id != host.id }
        HStack(spacing: 6) {
            if let jumpID = host.jumpHostID {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16)
                    if let jump = hostStore.host(jumpID) {
                        Text("경유: \(jump.displayName)")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text("경유 호스트를 찾을 수 없음")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Button { form.host.jumpHostID = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                        .help("경유 해제")
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.5)))
            } else {
                PanelField(icon: "arrow.triangle.branch", placeholder: "점프 호스트 (예: ubuntu@1.2.3.4:22)", text: optional($form.host.jumpHost))
            }
            Menu {
                Section("저장된 호스트를 경유 (키·포트 적용)") {
                    ForEach(candidates) { candidate in
                        Button(candidate.displayName) {
                            form.host.jumpHostID = candidate.id
                            form.host.jumpHost = nil
                        }
                    }
                }
                if host.jumpHostID != nil || host.jumpHost != nil {
                    Divider()
                    Button("경유 안 함") {
                        form.host.jumpHostID = nil
                        form.host.jumpHost = nil
                    }
                }
            } label: {
                Image(systemName: "chevron.down").foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(candidates.isEmpty)
            .help("저장된 호스트에서 고르기")
        }
    }

    private var notesSection: some View {
        PanelSection(title: "메모") {
            TextField("", text: optional($form.host.notes), prompt: Text("선택").foregroundStyle(Theme.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        }
    }

    // MARK: - 아래 버튼

    private var footer: some View {
        Button(action: isNew ? add : connect) {
            Text(isNew ? "추가" : "연결")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(form.validationError != nil)
        .opacity(form.validationError != nil ? 0.5 : 1)
        .keyboardShortcut(.defaultAction)
        .padding(16)
    }

    // MARK: - 동작

    /// 기존 호스트는 입력이 멈추면 자동 저장한다.
    private func scheduleSave() {
        guard !isNew else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            _ = saveNow()
        }
    }

    private func flushSave() {
        guard !isNew, saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        _ = saveNow()
    }

    /// 검증해서 저장하고 저장된 호스트를 돌려준다. 입력이 잘못되었으면 nil.
    @discardableResult
    private func saveNow() -> SSHHost? {
        guard let host = try? form.build() else { return nil }
        do {
            try hostStore.save(host)
            if host.authMethod == .password, !password.isEmpty, password != savedPassword {
                Keychain.savePassword(password, hostID: host.id)
                savedPassword = password
                hasSavedPassword = true
            }
            errorMessage = nil
            withAnimation { savedAt = Date() }
            return host
        } catch {
            errorMessage = "저장하지 못했습니다: \(error.localizedDescription)"
            return nil
        }
    }

    private func add() {
        guard let host = saveNow() else { return }
        onCreated(host.id)
    }

    private func connect() {
        saveTask?.cancel()
        guard let host = saveNow() else { return }
        store.connect(host)
    }

    private func delete() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try hostStore.delete(host.id)
            onClose()
        } catch {
            errorMessage = "삭제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func close() {
        flushSave()
        onClose()
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "SSH 개인 키 선택"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            form.host.identityFile = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// String? 를 입력 칸에 묶는다. 빈 문자열은 nil.
    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - 패널 구성 요소

/// 패널 안의 둥근 묶음
private struct PanelSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    }
}

/// 아이콘이 붙은 한 줄 입력 칸
private struct PanelField: View {
    let icon: String?
    let placeholder: String
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
    }
}

private struct PanelSecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)
            SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
    }
}
