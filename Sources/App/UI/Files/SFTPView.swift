import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SFTP 탭: 왼쪽 로컬 | 오른쪽 원격. 두 칸 사이로 끌어서 전송한다.
struct SFTPView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var local: LocalBrowser
    /// 왼쪽 칸이 차지하는 비율. 오른쪽 내용(호스트 고르기 ↔ 파일 목록)이 바뀌어도 유지된다.
    /// (HSplitView 는 내용이 원하는 폭으로 다시 나눠 서버에 들어가면 오른쪽이 줄어들었다)
    @AppStorage("sftp.splitRatio") private var ratio = 0.5
    @State private var dragStartRatio: Double?

    static let minPaneWidth: CGFloat = 280

    /// 전체 폭과 비율로 두 칸의 폭을 정한다 (각 칸 최소 280pt)
    static func paneWidths(total: CGFloat, ratio: Double) -> (left: CGFloat, right: CGFloat) {
        let usable = max(0, total - PanelResizeHandle.thickness)
        guard usable >= minPaneWidth * 2 else { return (usable / 2, usable / 2) }
        let left = min(max(usable * CGFloat(ratio), minPaneWidth), usable - minPaneWidth)
        return (left, usable - left)
    }

    var body: some View {
        GeometryReader { geo in
            let widths = Self.paneWidths(total: geo.size.width, ratio: ratio)
            HStack(spacing: 0) {
                LocalBrowserPanel(browser: local) { urls in
                    // 왼쪽에서 오른쪽 메뉴로 "원격으로 올리기"
                    guard let remote = store.sftpRemote else { return }
                    Task { await remote.upload(urls) }
                }
                .frame(width: widths.left)

                ResizeBar(
                    help: "끌어서 두 칸 폭 조절 · 더블클릭: 반반",
                    onChanged: { dx in
                        let start = dragStartRatio ?? ratio
                        dragStartRatio = start
                        let usable = max(1, geo.size.width - PanelResizeHandle.thickness)
                        ratio = min(max(start + Double(dx / usable), 0.1), 0.9)
                    },
                    onEnded: { dragStartRatio = nil },
                    onReset: { ratio = 0.5 })

                Group {
                    if let remote = store.sftpRemote {
                        FileBrowserPanel(
                            browser: remote,
                            title: remote.launch.title,
                            onClose: { store.closeSFTPRemote() },
                            localDestination: { local.directory },
                            onDownloaded: { local.refresh() })
                            .id(ObjectIdentifier(remote))
                    } else {
                        SFTPHostPicker()
                    }
                }
                .frame(width: widths.right)
            }
        }
        .background(Theme.contentBackground)
    }
}

// MARK: - 로컬 칸

struct LocalBrowserPanel: View {
    @ObservedObject var browser: LocalBrowser
    /// 오른쪽 원격 칸으로 올리기 (원격이 연결되어 있을 때)
    var uploadToRemote: (([URL]) -> Void)?

    @EnvironmentObject private var store: WorkspaceStore
    @State private var selection: Set<URL> = []
    @State private var dropTargeted = false
    @State private var renaming: LocalEntry?
    @State private var newFolderPrompt = false
    @State private var nameInput = ""
    @State private var panelWidth: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if let error = browser.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    Spacer()
                    Button { browser.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }
            list
        }
        .background(Theme.sidebarBackground)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { panelWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in panelWidth = width }
        })
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("새 이름", text: $nameInput)
            Button("바꾸기") { if let entry = renaming { browser.rename(entry, to: nameInput) } }
            Button("취소", role: .cancel) {}
        }
        .alert("새 폴더", isPresented: $newFolderPrompt) {
            TextField("폴더 이름", text: $nameInput)
            Button("만들기") { browser.makeFolder(named: nameInput) }
            Button("취소", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "laptopcomputer").foregroundStyle(Theme.textSecondary)
                Text("이 Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            ViewThatFits(in: .horizontal) {
                toolbarRow(labels: true)
                toolbarRow(labels: false)
            }
            pathBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(browser.pathComponents.enumerated()), id: \.offset) { index, part in
                    if index > 1 {
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Button(part.name) { browser.open(part.url) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(index == browser.pathComponents.count - 1 ? Theme.textPrimary : Theme.textSecondary)
                }
            }
        }
        .defaultScrollAnchor(.trailing)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
        .help(browser.path)
    }

    /// 도구 막대: 이름표가 들어갈 만큼 넓으면 아이콘 아래 이름을, 좁으면 아이콘만 보인다.
    private func toolbarRow(labels: Bool) -> some View {
        HStack(spacing: 2) {
            toolButton("chevron.up", "상위", "상위 폴더", labels: labels) { browser.goUp() }
            toolButton("arrow.clockwise", "새로고침", "새로고침", labels: labels) { browser.refresh() }
            toolButton("folder.badge.plus", "새 폴더", "새 폴더 만들기", labels: labels) { nameInput = ""; newFolderPrompt = true }
            toolButton("house", "홈", "홈 폴더로 이동", labels: labels) { browser.open(FileManager.default.homeDirectoryForCurrentUser) }
            toolButton("arrow.down.circle", "다운로드", "다운로드 폴더로 이동", labels: labels) { browser.open(FileBrowserPanel.downloadsFolder) }
            toolButton("macwindow", "Finder", "Finder 에서 열기", labels: labels) { NSWorkspace.shared.open(browser.directory) }
            Spacer(minLength: 4)
            FileToolbarButton(
                symbol: browser.showHidden ? "eye" : "eye.slash", label: "숨김 파일",
                help: browser.showHidden ? "숨김 파일 감추기" : "숨김 파일 보기",
                showsLabel: labels, isOn: browser.showHidden) { browser.showHidden.toggle() }
        }
    }

    private func toolButton(_ symbol: String, _ label: String, _ help: String, labels: Bool, action: @escaping () -> Void) -> some View {
        FileToolbarButton(symbol: symbol, label: label, help: help, showsLabel: labels, action: action)
    }

    private var list: some View {
        FileListView(
            items: browser.entries,
            selection: $selection,
            row: { entry in
                FileRowView(
                    name: entry.name, path: entry.url.path, isDirectory: entry.isDirectory, isSymlink: entry.isSymlink,
                    size: entry.size, modified: entry.modified, showsDate: panelWidth >= 400)
            },
            // 끌면 파일 URL 로 넘긴다 → 원격 칸·Finder 어디로든
            dragProvider: { entry in NSItemProvider(object: entry.url as NSURL) },
            menu: { items in AnyView(menu(items)) },
            primaryAction: { items in
                if items.count == 1, items[0].isDirectory {
                    browser.open(items[0].url)
                } else {
                    items.forEach { NSWorkspace.shared.open($0.url) }
                }
            },
            dropTypes: [.fileURL, .data, .folder],   // .folder: 원격 칸에서 끈 폴더
            onDrop: handleDrop,
            dropTargeted: $dropTargeted)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .background(Theme.accent.opacity(0.08))
                    .overlay(
                        Text("여기에 놓으면 \(browser.directory.lastPathComponent) 로 받기")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: browser.directory) { _, _ in selection = [] }
    }

    @ViewBuilder
    private func menu(_ items: [LocalEntry]) -> some View {
        if items.isEmpty {
            Button("새 폴더…") { nameInput = ""; newFolderPrompt = true }
            Button("새로고침") { browser.refresh() }
            Button("Finder 에서 열기") { NSWorkspace.shared.open(browser.directory) }
        } else {
            if let uploadToRemote, store.sftpRemote?.state == .connected {
                Button("원격으로 올리기 → \(store.sftpRemote?.path ?? "")") { uploadToRemote(items.map(\.url)) }
                Divider()
            }
            Button("열기") { items.forEach { NSWorkspace.shared.open($0.url) } }
            Button("Finder 에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
            if items.count == 1 {
                Button("이름 바꾸기…") { nameInput = items[0].name; renaming = items[0] }
            }
            Divider()
            Button("휴지통으로 이동", role: .destructive) { browser.moveToTrash(items) }
        }
    }

    /// Finder 의 파일은 복사하고, 원격 칸에서 끌어온 파일은 받아서(다운로드) 넣는다.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let destination = browser.directory
        // 앱 안의 서버 칸에서 끈 파일: 시스템이 넘겨주는 파일을 받지 않고 서버에서 바로 내려받는다
        // (원래 이름 그대로, 전송 목록에 진행률 표시, 시스템 파일 약속을 남기지 않음)
        if let drag = SFTPInAppDrag.take(for: providers) {
            dragLog.info("앱 안에 놓음: 서버에서 바로 받음 \(drag.entries.count, privacy: .public)개")
            Task {
                await drag.browser.download(drag.entries, to: destination)
                browser.refresh()
            }
            return true
        }
        Task {
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await Self.loadURL(provider) {
                    browser.copyIn([url])
                } else if let type = SFTPDragName.fileType(of: provider) {
                    // 원격 칸에서 끈 파일: 놓는 순간 받아 온 임시 파일을 이 폴더로 옮긴다.
                    // 이름은 원격 칸이 실어 보낸 원래 이름을 쓴다 (시스템이 확장자를 한 번 더 붙이는 문제)
                    let exact = await SFTPDragName.load(from: provider)
                    let suggested = provider.suggestedName
                    let received: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                            guard let url else { return continuation.resume(returning: nil) }
                            let name = SFTPDragName.resolvedName(exact: exact, suggested: suggested, fileName: url.lastPathComponent)
                            let target = RemoteBrowser.uniqueURL(destination.appendingPathComponent(name))
                            do {
                                try FileManager.default.copyItem(at: url, to: target)
                                continuation.resume(returning: target)
                            } catch {
                                continuation.resume(returning: nil)
                            }
                        }
                    }
                    if received == nil { browser.errorMessage = "파일을 받지 못했습니다." }
                }
            }
            browser.refresh()
        }
        return true
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

// MARK: - 호스트 고르기

/// SFTP 탭 오른쪽 칸: 연결할 호스트를 고른다.
struct SFTPHostPicker: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var hostStore: HostStore
    @State private var query = ""

    private var hosts: [SSHHost] { hostStore.hosts.filter { $0.matches(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack").foregroundStyle(Theme.textSecondary)
                    Text("원격 서버 선택")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                    TextField("", text: $query, prompt: Text("호스트 검색 또는 user@hostname").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.textPrimary)
                        .onSubmit(submit)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            }
            .padding(12)

            Rectangle().fill(Theme.divider).frame(height: 1)

            if hostStore.hosts.isEmpty && store.recentTargets.isEmpty {
                Text("저장된 호스트가 없습니다.\n위에 user@hostname 을 입력하고 Enter 를 누르세요.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(hosts) { host in
                        pickerRow(title: host.displayName, subtitle: host.subtitle, icon: "server.rack") {
                            store.openSFTP(host)
                        }
                    }
                    ForEach(store.recentTargets.filter { query.isEmpty || $0.raw.localizedCaseInsensitiveContains(query) }) { target in
                        pickerRow(title: target.displayName, subtitle: "최근 빠른 연결", icon: "bolt.fill") {
                            store.openSFTP(target)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.sidebarBackground)
    }

    private func pickerRow(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.hostIcon)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.contains("@"), let first = hosts.first {
            store.openSFTP(first)
        } else if let target = QuickConnectTarget(q) {
            store.openSFTP(target)
        }
    }
}
