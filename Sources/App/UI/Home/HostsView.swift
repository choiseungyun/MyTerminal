import AppKit
import SwiftUI

/// 오른쪽 패널에 보이는 것
enum HostInspector: Equatable {
    /// 저장된 호스트 정보·편집
    case edit(UUID)
    /// 아직 저장하지 않은 새 호스트 (새로 만들기, 복제, 빠른 연결 저장)
    case new(SSHHost)
}

/// 호스트 정렬 기준
enum HostSort: String, CaseIterable, Identifiable {
    case name, recent
    var id: String { rawValue }
    var title: String { self == .name ? "이름순" : "최근 접속순" }
}

/// 호스트 화면: 검색·빠른 연결 + 도구 막대 + 그룹별 호스트 카드
struct HostsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var hostStore: HostStore
    @State private var query = ""
    @State private var inspector: HostInspector?
    @State private var selectedHostID: UUID?
    @State private var deleting: SSHHost?
    @State private var importing = false
    @State private var exporting = false
    @State private var importFile: HostImportPicker.Loaded?
    @State private var importError: String?
    @AppStorage("hosts.sort") private var sort: HostSort = .name
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 14)]

    private var filteredHosts: [SSHHost] {
        let hosts = hostStore.hosts.filter { $0.matches(query) }
        switch sort {
        case .name:
            return hosts
        case .recent:
            return hosts.sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        }
    }

    /// 그룹별 묶음. 그룹 없는 호스트는 맨 뒤 "그룹 없음".
    private var groupedHosts: [(title: String, hosts: [SSHHost])] {
        let grouped = Dictionary(grouping: filteredHosts) { $0.group?.isEmpty == false ? $0.group! : "" }
        let named = grouped.keys.filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { (title: $0, hosts: grouped[$0]!) }
        let ungrouped = grouped[""].map { [(title: named.isEmpty ? "호스트" : "그룹 없음", hosts: $0)] } ?? []
        return named + ungrouped
    }

    private var filteredRecents: [QuickConnectTarget] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.recentTargets }
        return store.recentTargets.filter { $0.raw.localizedCaseInsensitiveContains(q) }
    }

    /// Enter 를 눌렀을 때 할 일
    private enum SubmitAction {
        case host(SSHHost)
        case quick(QuickConnectTarget)
    }

    private var submitAction: SubmitAction? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        // "user@host" 나 "ssh ..." 는 빠른 연결, 그 밖에는 검색 결과의 첫 호스트
        if !q.contains("@"), !q.hasPrefix("ssh "), let first = filteredHosts.first { return .host(first) }
        return QuickConnectTarget(q).map(SubmitAction.quick)
    }

    var body: some View {
        HStack(spacing: 0) {
            hostList
            if let inspector {
                Rectangle().fill(Theme.divider).frame(width: 1)
                inspectorPanel(inspector)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
        .sheet(isPresented: $importing) {
            SSHConfigImportView()
                .environmentObject(hostStore)
        }
        .sheet(isPresented: $exporting) {
            HostExportView()
                .environmentObject(hostStore)
        }
        .sheet(item: $importFile) { file in
            HostImportView(fileName: file.fileName, incoming: file.hosts)
                .environmentObject(hostStore)
        }
        .alert("가져올 수 없습니다", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog(
            "\"\(deleting?.displayName ?? "")\" 을(를) 삭제할까요?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { host in
            Button("삭제", role: .destructive) { delete(host) }
        } message: { _ in
            Text("저장된 비밀번호도 함께 지워집니다.")
        }
    }

    @ViewBuilder
    private func inspectorPanel(_ inspector: HostInspector) -> some View {
        switch inspector {
        case .edit(let id):
            if let host = hostStore.host(id) {
                HostDetailPanel(
                    host: host, isNew: false,
                    onClose: closeInspector,
                    onCreated: { _ in },
                    onDuplicate: { openNew(Self.duplicate($0)) })
                .id(id)
            }
        case .new(let host):
            HostDetailPanel(
                host: host, isNew: true,
                onClose: closeInspector,
                onCreated: { id in
                    selectedHostID = id
                    self.inspector = .edit(id)
                },
                onDuplicate: { _ in })
            .id(host.id)
        }
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
                .padding(.horizontal, 20)
                .padding(.top, 16)

            toolbar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if hostStore.hosts.isEmpty && store.recentTargets.isEmpty {
                        EmptyHostsCard { openNew(SSHHost()) }
                    }
                    ForEach(groupedHosts, id: \.title) { section in
                        hostSection(section.title, section.hosts)
                    }
                    if !filteredRecents.isEmpty {
                        recentSection
                    }
                    if !query.isEmpty && groupedHosts.isEmpty && filteredRecents.isEmpty {
                        Text("검색 결과가 없습니다. Enter 를 누르면 \"\(query)\" 로 바로 연결합니다.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.contentBackground)
        .onAppear { searchFocused = true }
    }

    private func pickImportFile() {
        do {
            importFile = try HostImportPicker.pick()
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - 패널 열고 닫기

    private func openEditor(_ id: UUID) {
        selectedHostID = id
        withAnimation(.easeOut(duration: 0.2)) { inspector = .edit(id) }
    }

    private func openNew(_ host: SSHHost) {
        selectedHostID = nil
        withAnimation(.easeOut(duration: 0.2)) { inspector = .new(host) }
    }

    private func closeInspector() {
        withAnimation(.easeOut(duration: 0.2)) { inspector = nil }
    }

    /// 카드 선택. 패널이 열려 있으면 그 호스트로 바꾼다 (Termius 와 같은 동작).
    private func select(_ id: UUID) {
        selectedHostID = id
        if case .edit = inspector { inspector = .edit(id) }
    }

    private func delete(_ host: SSHHost) {
        try? hostStore.delete(host.id)
        if inspector == .edit(host.id) { closeInspector() }
        if selectedHostID == host.id { selectedHostID = nil }
    }

    private static func duplicate(_ host: SSHHost) -> SSHHost {
        var copy = host
        copy.id = UUID()
        copy.name = host.displayName + " 복사본"
        copy.lastConnectedAt = nil
        copy.createdAt = Date()
        return copy
    }

    private func hostSection(_ title: String, _ hosts: [SSHHost]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: title, count: hosts.count)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(hosts) { host in
                    HostCard(
                        title: host.displayName,
                        subtitle: host.subtitle,
                        tags: host.tags,
                        icon: host.authMethod == .password ? "lock.fill" : "server.rack",
                        help: SSHCommand.launch(for: host).displayCommand,
                        isSelected: selectedHostID == host.id,
                        select: { select(host.id) },
                        edit: { openEditor(host.id) },
                        connect: { store.connect(host) })
                    .contextMenu { hostMenu(host) }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "최근 빠른 연결", count: filteredRecents.count)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(filteredRecents) { target in
                    HostCard(
                        title: target.displayName,
                        subtitle: ["ssh", target.user].compactMap { $0 }.joined(separator: ", "),
                        tags: [],
                        icon: "bolt.fill",
                        help: target.sshCommand,
                        isSelected: false,
                        select: {},
                        edit: { openNew(Self.host(from: target)) },
                        editSymbol: "square.and.arrow.down",
                        editHelp: "호스트로 저장",
                        connect: { store.connect(target) })
                    .contextMenu {
                        Button("연결") { store.connect(target) }
                        Button("호스트로 저장…") { openNew(Self.host(from: target)) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hostMenu(_ host: SSHHost) -> some View {
        Button("새 탭에서 연결") { store.connect(host) }
        Button("연결하고 파일 보기 (SFTP)") { store.connect(host, showFiles: true) }
        Button("SFTP 탭에서 열기") { store.openSFTP(host) }
        if store.hasTerminalTab {
            Button("분할 화면으로 연결") { store.connectInSplit(host) }
        }
        Divider()
        Button("편집") { openEditor(host.id) }
        Button("복제") { openNew(Self.duplicate(host)) }
        Button("ssh 명령 복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SSHCommand.launch(for: host).displayCommand, forType: .string)
        }
        Divider()
        Button("삭제…", role: .destructive) { deleting = host }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("", text: $query, prompt: Text("호스트 검색 또는 ssh user@hostname...")
                    .foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($searchFocused)
                    .onSubmit(submit)

                Button("연결", action: submit)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(submitAction == nil ? Theme.textTertiary : Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.selection))
                    .disabled(submitAction == nil)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))

            // Enter 가 무엇을 할지 미리 알려 준다
            Group {
                switch submitAction {
                case .host(let host): Text("Enter: \(host.displayName) 에 연결")
                case .quick(let target): Text("Enter: \(target.sshCommand) 실행")
                case nil: Text(" ")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 14)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ToolbarButton(symbol: "plus", title: "새 호스트") {
                openNew(SSHHost())
            }
            Menu {
                Button("파일에서 가져오기…", action: pickImportFile)
                Button("~/.ssh/config 에서 가져오기…") { importing = true }
                Divider()
                Button("내보내기…") { exporting = true }
                    .disabled(hostStore.hosts.isEmpty)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.arrow.down.square").font(.system(size: 13, weight: .semibold))
                    Text("가져오기 · 내보내기").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            ToolbarButton(symbol: "terminal", title: "로컬 터미널") {
                store.openLocalTerminal()
            }
            Spacer()
            Menu {
                Picker("정렬", selection: $sort) {
                    ForEach(HostSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 14))
    }

    private func submit() {
        switch submitAction {
        case .host(let host): store.connect(host)
        case .quick(let target): store.connect(target)
        case nil: return
        }
        query = ""
    }

    /// 빠른 연결 대상을 저장용 호스트로 바꾼다.
    private static func host(from target: QuickConnectTarget) -> SSHHost {
        SSHHost(quickConnect: target)
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(count)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 호스트 카드: 아이콘, 이름, "ssh, 사용자", 태그.
/// 클릭: 선택 · 연필 버튼: 편집 패널 · 더블클릭: 연결
struct HostCard: View {
    let title: String
    let subtitle: String
    let tags: [String]
    let icon: String
    let help: String
    let isSelected: Bool
    let select: () -> Void
    let edit: () -> Void
    var editSymbol = "pencil"
    var editHelp = "편집"
    let connect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.hostIcon)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.selection))
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: edit) {
                Image(systemName: editSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.selection))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
            .help(editHelp)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovering || isSelected ? Theme.cardHover : Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.accent, lineWidth: isSelected ? 2 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            // 한 번 클릭은 바로 선택하고, 두 번째 클릭(더블클릭)이면 연결한다.
            // (onTapGesture(count: 2) 를 같이 쓰면 한 번 클릭이 늦게 반응한다)
            if NSApp.currentEvent?.clickCount == 2 {
                connect()
            } else {
                select()
            }
        }
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct EmptyHostsCard: View {
    let addHost: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("아직 저장된 호스트가 없습니다")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("위 검색창에 user@hostname 을 입력하고 Enter 를 누르면 바로 연결됩니다.\n자주 쓰는 서버는 호스트로 저장해 두면 카드를 더블클릭해 접속할 수 있습니다.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
            Button("새 호스트 추가", action: addHost)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
