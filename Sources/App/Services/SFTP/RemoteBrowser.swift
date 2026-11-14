import Foundation
import SwiftUI

/// 전송 하나 (업로드·다운로드). 폴더는 안의 파일을 합쳐 하나로 보여 준다.
struct FileTransfer: Identifiable, Equatable {
    enum Direction { case upload, download }
    enum State: Equatable {
        case running
        case done
        case failed(String)
    }

    let id = UUID()
    var name: String
    var direction: Direction
    var totalBytes: UInt64
    var doneBytes: UInt64 = 0
    var state: State = .running
    /// 다운로드가 끝난 로컬 위치 (Finder 에서 보기)
    var localURL: URL?

    var fraction: Double {
        guard totalBytes > 0 else { return state == .done ? 1 : 0 }
        return min(1, Double(doneBytes) / Double(totalBytes))
    }
}

/// 원격 파일 탐색기 상태. 터미널 화면(SSH) 하나 또는 SFTP 탭의 원격 칸 하나가 하나씩 가진다.
@MainActor
final class RemoteBrowser: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    let launch: SSHLaunch

    @Published private(set) var state: State = .idle
    @Published private(set) var path = ""
    @Published private(set) var entries: [SFTPEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var transfers: [FileTransfer] = []
    /// 마지막 작업 오류 (패널 위에 잠깐 보여 준다)
    @Published var errorMessage: String?
    @Published var showHidden = false {
        didSet { applyFilter() }
    }

    /// 연결을 여는 방법 (테스트에서는 로컬 sftp-server 로 바꿔 끼운다)
    typealias Opener = (SSHLaunch) async throws -> (client: SFTPClient, close: () -> Void)

    private let opener: Opener
    private var connection: (client: SFTPClient, close: () -> Void)?
    private var allEntries: [SFTPEntry] = []

    init(launch: SSHLaunch, opener: Opener? = nil) {
        self.launch = launch
        self.opener = opener ?? { launch in
            let connection = try await SFTPConnection.open(launch)
            return (connection.client, connection.close)
        }
    }

    deinit {
        connection?.close()
    }

    var client: SFTPClient? { connection?.client }

    /// 원격 파일 편집 (로컬 편집기로 열고 저장하면 올리기)
    lazy var editor = RemoteEditor(client: { [weak self] in self?.client })

    // MARK: - 연결

    func connectIfNeeded() async {
        guard state == .idle || isFailed else { return }
        state = .connecting
        do {
            let connection = try await opener(launch)
            self.connection = connection
            state = .connected
            let home = (try? await connection.client.realpath(".")) ?? "/"
            await open(home)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reconnect() async {
        connection?.close()
        connection = nil
        state = .idle
        await connectIfNeeded()
    }

    func disconnect() {
        connection?.close()
        connection = nil
        state = .idle
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - 탐색

    func open(_ newPath: String) async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let resolved = try await client.realpath(newPath.isEmpty ? "." : newPath)
            let items = try await client.list(resolved)
            path = resolved
            allEntries = items
            applyFilter()
            errorMessage = nil
        } catch {
            await handle(error)
        }
    }

    func refresh() async { await open(path) }

    func goUp() async {
        guard path != "/" else { return }
        await open((path as NSString).deletingLastPathComponent)
    }

    /// 경로를 / 기준으로 나눈 조각 (경로 표시줄의 버튼용)
    var pathComponents: [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    private func applyFilter() {
        entries = allEntries
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    // MARK: - 변경

    func makeFolder(named name: String) async {
        guard let client, let name = Self.validName(name) else { return }
        await perform { try await client.mkdir(SFTPClient.join(self.path, name)) }
    }

    func rename(_ entry: SFTPEntry, to name: String) async {
        guard let client, let name = Self.validName(name), name != entry.name else { return }
        let target = SFTPClient.join((entry.path as NSString).deletingLastPathComponent, name)
        await perform { try await client.rename(entry.path, to: target) }
    }

    func delete(_ items: [SFTPEntry]) async {
        guard let client else { return }
        await perform {
            for item in items {
                if item.isDirectory && !item.isSymlink {
                    try await client.removeRecursively(item.path)
                } else {
                    try await client.remove(item.path)
                }
            }
        }
    }

    /// 작업 후 목록을 새로 읽는다. 실패하면 오류를 보여 준다.
    private func perform(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
        } catch {
            await handle(error)
        }
        await refresh()
    }

    private func handle(_ error: Error) async {
        if case SFTPError.connectionLost = error {
            state = .failed(error.localizedDescription)
            connection = nil
        } else {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 업로드

    /// 로컬 파일·폴더를 지금 폴더(또는 지정한 폴더)에 올린다. 폴더는 안의 내용까지.
    func upload(_ urls: [URL], to directory: String? = nil) async {
        guard let client else { return }
        let destination = directory ?? path
        for url in urls {
            let files = Self.localFiles(under: url)
            let total = files.reduce(UInt64(0)) { $0 + $1.size }
            let transferID = startTransfer(FileTransfer(name: url.lastPathComponent, direction: .upload, totalBytes: total))
            var base: UInt64 = 0
            do {
                for file in files {
                    let remote = SFTPClient.join(destination, file.relativePath)
                    if file.isDirectory {
                        try? await client.mkdir(remote)   // 이미 있으면 무시
                        continue
                    }
                    let offset = base
                    try await client.upload(file.url, to: remote) { [weak self] sent in
                        Task { @MainActor in self?.updateTransfer(transferID, done: offset + sent) }
                    }
                    base += file.size
                }
                finishTransfer(transferID)
            } catch {
                failTransfer(transferID, error)
            }
        }
        if destination == path { await refresh() }
    }

    private struct LocalFile {
        var url: URL
        /// 올리는 항목 이름부터 시작하는 상대 경로 (예: "project/src/main.c")
        var relativePath: String
        var isDirectory: Bool
        var size: UInt64
    }

    /// 폴더면 안의 파일까지 (폴더가 먼저 오도록) 펼친다.
    private static func localFiles(under url: URL) -> [LocalFile] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        let name = url.lastPathComponent
        guard isDir.boolValue else {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            return [LocalFile(url: url, relativePath: name, isDirectory: false, size: size)]
        }

        var result = [LocalFile(url: url, relativePath: name, isDirectory: true, size: 0)]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys) else { return result }
        let basePath = url.standardizedFileURL.path
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let relative = name + String(child.standardizedFileURL.path.dropFirst(basePath.count))
            result.append(LocalFile(
                url: child,
                relativePath: relative,
                isDirectory: values?.isDirectory ?? false,
                size: UInt64(values?.fileSize ?? 0)))
        }
        return result
    }

    // MARK: - 다운로드

    /// 원격 파일·폴더를 로컬 폴더로 받는다. 같은 이름이 있으면 " 2" 를 붙인다.
    func download(_ items: [SFTPEntry], to directory: URL) async {
        guard let client else { return }
        for item in items {
            let target = Self.uniqueURL(directory.appendingPathComponent(item.name))
            let transferID = startTransfer(FileTransfer(name: item.name, direction: .download, totalBytes: item.size))
            do {
                if item.isDirectory {
                    let files = try await Self.remoteFiles(client, under: item.path)
                    mutateTransfer(transferID) { $0.totalBytes = files.reduce(0) { $0 + $1.size } }
                    var base: UInt64 = 0
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    for file in files {
                        let local = target.appendingPathComponent(file.relativePath)
                        if file.isDirectory {
                            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                            continue
                        }
                        let offset = base
                        try await client.download(file.path, to: local) { [weak self] got in
                            Task { @MainActor in self?.updateTransfer(transferID, done: offset + got) }
                        }
                        base += file.size
                    }
                } else {
                    try await client.download(item.path, to: target) { [weak self] got in
                        Task { @MainActor in self?.updateTransfer(transferID, done: got) }
                    }
                }
                mutateTransfer(transferID) { $0.localURL = target }
                finishTransfer(transferID)
            } catch {
                try? FileManager.default.removeItem(at: target)
                failTransfer(transferID, error)
            }
        }
    }

    /// 끌어서 Finder 로 내보낼 때: 임시 폴더에 받아 그 위치를 돌려준다.
    func downloadToTemporary(_ item: SFTPEntry) async throws -> URL {
        guard let client else { throw SFTPError.connectionLost("") }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyTerminal-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(item.name)
        let transferID = startTransfer(FileTransfer(name: item.name, direction: .download, totalBytes: item.size))
        do {
            try await client.download(item.path, to: target) { [weak self] got in
                Task { @MainActor in self?.updateTransfer(transferID, done: got) }
            }
            finishTransfer(transferID)
            return target
        } catch {
            failTransfer(transferID, error)
            throw error
        }
    }

    private struct RemoteFile {
        var path: String
        var relativePath: String
        var isDirectory: Bool
        var size: UInt64
    }

    private static func remoteFiles(_ client: SFTPClient, under root: String, prefix: String = "") async throws -> [RemoteFile] {
        var result: [RemoteFile] = []
        for entry in try await client.list(root) {
            let relative = prefix.isEmpty ? entry.name : prefix + "/" + entry.name
            if entry.isDirectory && !entry.isSymlink {
                result.append(RemoteFile(path: entry.path, relativePath: relative, isDirectory: true, size: 0))
                result += try await remoteFiles(client, under: entry.path, prefix: relative)
            } else if !entry.isDirectory {
                result.append(RemoteFile(path: entry.path, relativePath: relative, isDirectory: false, size: entry.size))
            }
        }
        return result
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        for n in 2...999 {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
    }

    // MARK: - 전송 목록

    /// 전송을 목록에 넣고 id 를 돌려준다. 목록은 최근 30개까지 (끝난 것부터 지운다).
    private func startTransfer(_ transfer: FileTransfer) -> UUID {
        transfers.append(transfer)
        while transfers.count > 30, let old = transfers.firstIndex(where: { $0.state != .running }) {
            transfers.remove(at: old)
        }
        return transfer.id
    }

    private func mutateTransfer(_ id: UUID, _ change: (inout FileTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    /// 진행률 갱신은 다른 스레드에서 늦게 도착할 수 있으므로, 진행 중이고 값이 커질 때만 반영한다.
    private func updateTransfer(_ id: UUID, done: UInt64) {
        mutateTransfer(id) {
            guard $0.state == .running, done > $0.doneBytes else { return }
            $0.doneBytes = done
        }
    }

    private func finishTransfer(_ id: UUID) {
        mutateTransfer(id) {
            $0.doneBytes = $0.totalBytes
            $0.state = .done
        }
    }

    private func failTransfer(_ id: UUID, _ error: Error) {
        mutateTransfer(id) { $0.state = .failed(error.localizedDescription) }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }

    // MARK: - 도움

    /// 파일 이름으로 쓸 수 있는지 (빈 이름, "/", ".", ".." 금지)
    static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else { return nil }
        return trimmed
    }
}
