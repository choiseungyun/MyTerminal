import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 원격 파일 탐색기 (SFTP). 터미널 탭 오른쪽 패널과 SFTP 탭의 원격 칸에서 쓴다.
///
/// - 폴더 더블클릭: 들어가기 · 파일 더블클릭: 다운로드 폴더로 받기
/// - Finder 에서 파일·폴더를 끌어다 놓으면 지금 폴더로 업로드, 목록의 파일을 Finder 로 끌어내면 다운로드
/// - 우클릭: 다운로드, 다른 위치에 다운로드, 이름 바꾸기, 경로 복사, 삭제, 새 폴더, 업로드
struct FileBrowserPanel: View {
    @ObservedObject var browser: RemoteBrowser
    var title: String
    var onClose: (() -> Void)?
    /// SFTP 탭: 파일을 받을 로컬 칸의 폴더 (없으면 다운로드 폴더)
    var localDestination: (() -> URL)?
    /// 다운로드가 끝났을 때 (로컬 칸 새로고침)
    var onDownloaded: (() -> Void)?

    @State private var selection: Set<String> = []
    @State private var dropTargeted = false
    @State private var renaming: SFTPEntry?
    @State private var newFolderPrompt = false
    @State private var goToPrompt = false
    @State private var nameInput = ""
    @State private var deleting: [SFTPEntry] = []
    /// 패널 폭 (좁으면 수정 시각을 숨기고 이름에 공간을 준다)
    @State private var panelWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
            EditingList(editor: browser.editor)
            if !browser.transfers.isEmpty {
                Rectangle().fill(Theme.divider).frame(height: 1)
                TransferList(browser: browser)
            }
        }
        .background(Theme.sidebarBackground)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { panelWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in panelWidth = width }
        })
        .task { await browser.connectIfNeeded() }
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("새 이름", text: $nameInput)
            Button("바꾸기") {
                if let entry = renaming { Task { await browser.rename(entry, to: nameInput) } }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("새 폴더", isPresented: $newFolderPrompt) {
            TextField("폴더 이름", text: $nameInput)
            Button("만들기") { Task { await browser.makeFolder(named: nameInput) } }
            Button("취소", role: .cancel) {}
        }
        .alert("경로로 이동", isPresented: $goToPrompt) {
            TextField("예: /var/log", text: $nameInput)
            Button("이동") { Task { await browser.open(nameInput) } }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog(
            deleting.count == 1 ? "\"\(deleting[0].name)\" 을(를) 삭제할까요?" : "\(deleting.count)개 항목을 삭제할까요?",
            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })
        ) {
            Button("삭제", role: .destructive) {
                let items = deleting
                Task { await browser.delete(items) }
            }
        } message: {
            Text(deleting.contains { $0.isDirectory } ? "폴더는 안의 내용까지 서버에서 지워집니다. 되돌릴 수 없습니다." : "서버에서 지워지며 되돌릴 수 없습니다.")
        }
    }

    // MARK: - 머리글

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if let onClose {
                    iconButton("arrow.right.to.line", "패널 닫기", action: onClose)
                }
            }
            ViewThatFits(in: .horizontal) {
                toolbarRow(labels: true)
                toolbarRow(labels: false)
            }
            .disabled(browser.state != .connected)
            pathBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var pathBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(browser.pathComponents.enumerated()), id: \.offset) { index, part in
                        if index > 1 {
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Button(part.name) { Task { await browser.open(part.path) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(index == browser.pathComponents.count - 1 ? Theme.textPrimary : Theme.textSecondary)
                            .id(index)
                    }
                }
            }
            .onChange(of: browser.path) { _, _ in
                proxy.scrollTo(browser.pathComponents.count - 1, anchor: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
        .help(browser.path)
    }

    /// 도구 막대: 이름표가 들어갈 만큼 넓으면 아이콘 아래 이름을, 좁으면 아이콘만 보인다.
    private func toolbarRow(labels: Bool) -> some View {
        HStack(spacing: 2) {
            toolButton("chevron.up", "상위", "상위 폴더", labels: labels) { Task { await browser.goUp() } }
                .disabled(browser.path == "/" || browser.state != .connected)
            toolButton("arrow.clockwise", "새로고침", "새로고침", labels: labels) { Task { await browser.refresh() } }
            toolButton("folder.badge.plus", "새 폴더", "새 폴더 만들기", labels: labels) { nameInput = ""; newFolderPrompt = true }
            toolButton("square.and.arrow.up", "업로드", "이 Mac 의 파일을 골라 업로드…", labels: labels, action: chooseUpload)
            toolButton("arrow.right.circle", "경로 이동", "경로를 입력해 이동…", labels: labels) { nameInput = browser.path; goToPrompt = true }
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

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 내용

    @ViewBuilder
    private var content: some View {
        switch browser.state {
        case .idle, .connecting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("연결 중…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("다시 연결") { Task { await browser.reconnect() } }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .connected:
            VStack(spacing: 0) {
                if let error = browser.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button { browser.errorMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12))
                }
                fileList
            }
        }
    }

    private var fileList: some View {
        FileListView(
            items: browser.entries,
            selection: $selection,
            row: { entry in
                FileRowView(
                    name: entry.name, path: entry.path, isDirectory: entry.isDirectory, isSymlink: entry.isSymlink,
                    size: entry.size, modified: entry.modified, showsDate: panelWidth >= 400)
            },
            dragProvider: { entry in entry.isDirectory ? nil : dragProvider(entry) },
            menu: { items in AnyView(menu(for: items)) },
            primaryAction: primaryAction,
            dropTypes: [.fileURL],
            onDrop: handleDrop,
            dropTargeted: $dropTargeted)
        .overlay {
            if browser.entries.isEmpty && !browser.isLoading {
                Text("비어 있는 폴더\n파일을 끌어다 놓으면 업로드합니다")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .background(Theme.accent.opacity(0.08))
                    .overlay(
                        Text("여기에 놓으면 \(browser.path) 로 업로드")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: browser.path) { _, _ in selection = [] }
    }

    private func items(_ paths: Set<String>) -> [SFTPEntry] {
        browser.entries.filter { paths.contains($0.path) }
    }

    // MARK: - 동작

    @ViewBuilder
    private func menu(for items: [SFTPEntry]) -> some View {
        if items.isEmpty {
            Button("새 폴더…") { nameInput = ""; newFolderPrompt = true }
            Button("업로드…", action: chooseUpload)
            Button("새로고침") { Task { await browser.refresh() } }
        } else {
            if items.count == 1, items[0].isDirectory {
                Button("열기") { Task { await browser.open(items[0].path) } }
                Divider()
            }
            if let localDestination {
                Button("로컬 칸으로 받기") { download(items, to: localDestination()) }
            }
            Button("다운로드 폴더로 받기") { download(items, to: Self.downloadsFolder) }
            Button("다른 위치에 받기…") { chooseDownloadFolder(items) }
            Divider()
            if items.count == 1, !items[0].isDirectory {
                Button("편집 (저장하면 서버에 올리기)") { edit(items[0], with: nil) }
                Button("다음 앱으로 편집…") { chooseEditor(for: items[0]) }
                Divider()
            }
            if items.count == 1 {
                Button("이름 바꾸기…") { nameInput = items[0].name; renaming = items[0] }
                Button("경로 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(items[0].path, forType: .string)
                }
            }
            Button("삭제…", role: .destructive) { deleting = items }
        }
    }

    private func primaryAction(_ items: [SFTPEntry]) {
        if items.count == 1, items[0].isDirectory {
            Task { await browser.open(items[0].path) }
        } else if !items.isEmpty {
            download(items.filter { !$0.isDirectory }, to: localDestination?() ?? Self.downloadsFolder)
        }
    }

    private func download(_ items: [SFTPEntry], to folder: URL) {
        Task {
            await browser.download(items, to: folder)
            onDownloaded?()
        }
    }

    private func edit(_ entry: SFTPEntry, with app: URL?) {
        Task {
            do {
                try await browser.editor.edit(entry, with: app)
            } catch {
                browser.errorMessage = "편집용으로 받지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    private func chooseEditor(for entry: SFTPEntry) {
        let panel = NSOpenPanel()
        panel.title = "\(entry.name) 을(를) 열 앱 선택"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let app = panel.url { edit(entry, with: app) }
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func chooseDownloadFolder(_ items: [SFTPEntry]) {
        let panel = NSOpenPanel()
        panel.title = "받을 위치 선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Self.downloadsFolder
        if panel.runModal() == .OK, let url = panel.url { download(items, to: url) }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.title = "\(browser.path) 로 업로드"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await browser.upload(urls) }
        }
    }

    /// Finder 에서 끌어다 놓은 파일·폴더를 업로드한다.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }
        let destination = browser.path
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadURL(provider), url.isFileURL { urls.append(url) }
            }
            await browser.upload(urls, to: destination)
        }
        return true
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    /// 파일을 Finder 등으로 끌어낼 때: 놓는 순간 임시 폴더로 받아 넘겨준다.
    private func dragProvider(_ entry: SFTPEntry) -> NSItemProvider {
        // 앱 안(SFTP 탭 이 Mac 칸)에 놓이면 이 기록으로 바로 내려받는다
        SFTPInAppDrag.begin(browser: browser, entries: [entry])
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    let url = try await browser.downloadToTemporary(entry)
                    progress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        // 앱 안(SFTP 탭 왼쪽 칸)에 놓을 때 쓸 정확한 이름
        SFTPDragName.register(entry.name, on: provider)
        return provider
    }
}

// MARK: - 행 (로컬·원격 공용)

struct FileRowView: View {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64
    let modified: Date?
    var showsDate = true

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yy.MM.dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isDirectory ? "folder.fill" : (isSymlink ? "link" : "doc"))
                .font(.system(size: 12))
                .foregroundStyle(isDirectory ? Theme.accent : Theme.textSecondary)
                .frame(width: 16)
            // 이름이 공간을 먼저 차지하고, 크기·시각은 줄어들지 않는다
            Text(name)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if !isDirectory {
                Text(Self.size(size))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }
            if showsDate, let modified {
                Text(Self.dateFormatter.string(from: modified))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(.vertical, 1)
        .help(tooltip)
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// 마우스를 올리면 전체 이름·크기·수정 시각·경로
    private var tooltip: String {
        var lines = [name]
        var info: [String] = []
        if !isDirectory { info.append(Self.size(size)) }
        if let modified { info.append(Self.dateFormatter.string(from: modified)) }
        if !info.isEmpty { lines.append(info.joined(separator: " · ")) }
        lines.append(path)
        return lines.joined(separator: "\n")
    }
}

// MARK: - 편집 중 목록

private struct EditingList: View {
    @ObservedObject var editor: RemoteEditor

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        if !editor.files.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, -10)
                Text("편집 중 · 저장하면 서버에 올라갑니다")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(editor.files) { file in
                    row(file)
                }
            }
            .padding(10)
        }
    }

    private func row(_ file: RemoteEditor.EditingFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").foregroundStyle(Theme.accent)
                Text(file.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button { editor.reopen(file.id) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help("편집기에서 다시 열기")
                Button { editor.stopEditing(file.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help("편집 끝내기 (로컬 사본 삭제)")
            }
            .help(file.remotePath)

            switch file.state {
            case .synced(let date):
                Text(date.map { "올림 \(Self.timeFormatter.string(from: $0))" } ?? "받음 · 아직 바뀐 내용 없음")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            case .uploading:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("올리는 중…").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                }
            case .conflict:
                VStack(alignment: .leading, spacing: 4) {
                    Text("받은 뒤 서버 파일이 바뀌었습니다.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                    HStack(spacing: 8) {
                        Button("내 것으로 덮어쓰기") { Task { await editor.upload(file.id, force: true) } }
                        Button("서버 버전 받기") { Task { await editor.reloadFromServer(file.id) } }
                    }
                    .controlSize(.small)
                }
            case .failed(let message):
                HStack(spacing: 6) {
                    Text(message).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
                    Button("다시 올리기") { Task { await editor.upload(file.id, force: true) } }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - 전송 목록

private struct TransferList: View {
    @ObservedObject var browser: RemoteBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("전송")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("완료 지우기") { browser.clearFinishedTransfers() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(browser.transfers.reversed()) { transfer in
                        TransferRow(transfer: transfer)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(10)
    }
}

private struct TransferRow: View {
    let transfer: FileTransfer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch transfer.state {
                case .running:
                    ProgressView(value: transfer.fraction).controlSize(.small)
                case .done:
                    Text("완료 · \(ByteCountFormatter.string(fromByteCount: Int64(transfer.totalBytes), countStyle: .file))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if transfer.state == .done, let url = transfer.localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Finder 에서 보기")
            }
        }
    }
}
