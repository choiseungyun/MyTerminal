import AppKit
import CryptoKit
import Foundation

/// 파일 하나의 변경을 감시한다.
/// 많은 편집기는 "새 파일에 쓰고 바꿔치기"로 저장하므로, 지워지거나 이름이 바뀌면 같은 경로를 다시 감시한다.
final class FileWatcher {
    let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func start(retries: Int = 20) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // 바꿔치기 중이라 아직 파일이 없을 수 있다 → 잠시 뒤 다시
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.start(retries: retries - 1) }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            self.onChange()
            if events.contains(.delete) || events.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.start() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
}

/// 원격 파일을 로컬 편집기로 열고, 저장하면 서버로 올린다.
@MainActor
final class RemoteEditor: ObservableObject {
    struct EditingFile: Identifiable, Equatable {
        enum State: Equatable {
            case synced(Date?)
            case uploading
            /// 받은 뒤 서버 파일이 바뀌었다 (덮어쓸지 사용자가 정한다)
            case conflict
            case failed(String)
        }

        let id = UUID()
        var name: String
        var remotePath: String
        var localURL: URL
        /// 마지막으로 받거나 올렸을 때 서버 파일의 수정 시각·크기.
        /// SFTP 의 수정 시각은 초 단위라, 같은 초 안에 서버에서 바뀐 것도 잡도록 크기도 함께 비교한다.
        var remoteModified: Date?
        var remoteSize: UInt64?
        /// 마지막으로 받거나 올린 내용 (같은 내용이면 다시 올리지 않는다)
        var digest: String
        var state: State
    }

    @Published private(set) var files: [EditingFile] = []

    private let client: () -> SFTPClient?
    private let openFile: (URL, URL?) -> Void
    private var watchers: [UUID: FileWatcher] = [:]
    private var pendingUploads: [UUID: Task<Void, Never>] = [:]
    /// 올리는 중인 파일과, 올리는 동안 또 저장된 파일 (같은 파일의 업로드는 한 번에 하나씩)
    private var uploading: Set<UUID> = []
    private var dirty: Set<UUID> = []
    let workDirectory: URL

    /// 저장 후 올리기까지 기다리는 시간 (연달아 저장하면 한 번만 올린다)
    var debounce: UInt64 = 400_000_000

    init(
        client: @escaping () -> SFTPClient?,
        workDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTerminal/Edit", isDirectory: true),
        openFile: ((URL, URL?) -> Void)? = nil
    ) {
        self.client = client
        self.workDirectory = workDirectory
        self.openFile = openFile ?? { url, app in
            if let app {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    deinit {
        watchers.values.forEach { $0.stop() }
    }

    /// 지난 실행에서 남은 편집용 사본을 지운다 (감시가 끝나 동기화되지 않는 파일들). 앱 시작 시 호출.
    nonisolated static func cleanUpPreviousSession() {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTerminal/Edit", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - 편집 시작·끝

    /// 원격 파일을 받아 편집기로 연다. 이미 편집 중이면 다시 연다.
    func edit(_ entry: SFTPEntry, with app: URL? = nil) async throws {
        if let existing = files.first(where: { $0.remotePath == entry.path }) {
            openFile(existing.localURL, app)
            return
        }
        guard let client = client() else { throw SFTPError.connectionLost("") }

        let folder = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent(entry.name)
        try await client.download(entry.path, to: local)
        let remote = try? await client.stat(entry.path)

        let file = EditingFile(
            name: entry.name,
            remotePath: entry.path,
            localURL: local,
            remoteModified: remote?.modified,
            remoteSize: remote?.size,
            digest: Self.digest(of: local),
            state: .synced(nil))
        files.append(file)
        let id = file.id
        watchers[id] = FileWatcher(url: local) { [weak self] in
            Task { @MainActor in self?.scheduleUpload(id) }
        }
        openFile(local, app)
    }

    func reopen(_ id: UUID) {
        guard let file = file(id) else { return }
        openFile(file.localURL, nil)
    }

    /// 편집을 끝낸다: 감시를 멈추고 로컬 사본을 지운다. (올리지 않은 변경은 버려진다)
    func stopEditing(_ id: UUID) {
        pendingUploads[id]?.cancel()
        pendingUploads[id] = nil
        watchers[id]?.stop()
        watchers[id] = nil
        if let file = file(id) {
            try? FileManager.default.removeItem(at: file.localURL.deletingLastPathComponent())
        }
        files.removeAll { $0.id == id }
    }

    func stopAll() {
        files.map(\.id).forEach(stopEditing)
    }

    // MARK: - 올리기

    /// 저장이 멈출 때까지 기다렸다가 올린다. 새 저장이 오면 기다림만 다시 시작하고,
    /// 이미 시작한 업로드는 취소하지 않는다 (진행 중 저장은 끝난 뒤 한 번 더 올림).
    private func scheduleUpload(_ id: UUID) {
        pendingUploads[id]?.cancel()
        let delay = debounce
        pendingUploads[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingUploads[id] = nil
            Task { @MainActor in await self.upload(id, force: false) }
        }
    }

    /// 로컬 사본을 서버로 올린다. force 가 아니면 서버 파일이 그사이 바뀌었는지 먼저 확인한다.
    func upload(_ id: UUID, force: Bool) async {
        // 이미 올리는 중이면 끝난 뒤 한 번 더 올린다. (동시에 올리면 내 업로드끼리 충돌로 보인다)
        guard !uploading.contains(id) else {
            dirty.insert(id)
            return
        }
        uploading.insert(id)
        await performUpload(id, force: force)
        uploading.remove(id)
        if dirty.remove(id) != nil {
            await upload(id, force: false)
        }
    }

    private func performUpload(_ id: UUID, force: Bool) async {
        guard var file = file(id) else { return }
        let digest = Self.digest(of: file.localURL)
        guard force || digest != file.digest else { return }   // 내용이 같으면 올리지 않는다
        guard let client = client() else {
            update(id) { $0.state = .failed("연결이 끊어졌습니다. 다시 연결한 뒤 \"덮어쓰기\" 하세요.") }
            return
        }

        if !force, let current = try? await client.stat(file.remotePath) {
            var changed = Self.changedOnServer(file, current)
            // 시각·크기가 같아도 같은 초 안에 같은 크기로 바뀌었을 수 있다 → 작은 파일은 내용까지 비교
            if !changed, let size = current.size, size <= Self.contentCheckLimit {
                changed = await serverContentDiffers(file, client: client)
            }
            if changed {
                update(id) { $0.state = .conflict }
                return
            }
        }

        update(id) { $0.state = .uploading }
        do {
            try await client.upload(file.localURL, to: file.remotePath)
            let remote = try? await client.stat(file.remotePath)
            update(id) {
                $0.digest = digest
                $0.remoteModified = remote?.modified
                $0.remoteSize = remote?.size
                $0.state = .synced(Date())
            }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// 충돌 시: 서버 버전으로 로컬 사본을 바꾼다.
    func reloadFromServer(_ id: UUID) async {
        guard let file = file(id), let client = client() else { return }
        do {
            try await client.download(file.remotePath, to: file.localURL)
            let remote = try? await client.stat(file.remotePath)
            let digest = Self.digest(of: file.localURL)
            update(id) {
                $0.remoteModified = remote?.modified
                $0.remoteSize = remote?.size
                $0.digest = digest
                $0.state = .synced(nil)
            }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    // MARK: - 도움

    /// 이 크기 이하 파일은 올리기 전에 서버 내용을 받아 마지막으로 맞춘 내용과 비교한다
    static let contentCheckLimit: UInt64 = 1_000_000

    /// 서버 내용이 마지막으로 받거나 올린 내용(digest)과 다른지. 받지 못하면 다르지 않은 것으로 본다.
    private func serverContentDiffers(_ file: EditingFile, client: SFTPClient) async -> Bool {
        let temp = workDirectory.appendingPathComponent("check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? await client.download(file.remotePath, to: temp)) != nil else { return false }
        return Self.digest(of: temp) != file.digest
    }

    /// 마지막으로 받거나 올린 뒤 서버 파일이 바뀌었는지 (수정 시각 또는 크기)
    nonisolated static func changedOnServer(_ file: EditingFile, _ current: SFTPAttributes) -> Bool {
        if let known = file.remoteModified, let now = current.modified, known != now { return true }
        if let known = file.remoteSize, let now = current.size, known != now { return true }
        return false
    }

    private func file(_ id: UUID) -> EditingFile? { files.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout EditingFile) -> Void) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        change(&files[index])
    }

    static func digest(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
