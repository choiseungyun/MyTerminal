import AppKit
import Foundation

/// 로컬 파일 하나
struct LocalEntry: Identifiable, Hashable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool
    var size: UInt64
    var modified: Date?

    var id: URL { url }
}

/// SFTP 탭 왼쪽 칸의 로컬 파일 탐색기
@MainActor
final class LocalBrowser: ObservableObject {
    @Published private(set) var directory: URL
    @Published private(set) var entries: [LocalEntry] = []
    @Published var errorMessage: String?
    @Published var showHidden = false {
        didSet { refresh() }
    }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.directory = directory.standardizedFileURL
        refresh()
    }

    var path: String { directory.path }

    /// 경로를 / 기준으로 나눈 조각 (경로 표시줄의 버튼용)
    ///
    /// URL 을 위로 따라 올라가면 "/" 에서 "/.." 가 계속 만들어져 끝나지 않을 수 있으므로,
    /// 경로 문자열을 "/" 로 나눠 만든다. (회귀: SFTP 탭을 열면 앱이 멈춤)
    var pathComponents: [(name: String, url: URL)] {
        var result: [(String, URL)] = [("/", URL(fileURLWithPath: "/", isDirectory: true))]
        var current = ""
        for part in directory.path.split(separator: "/") where !part.isEmpty {
            current += "/" + part
            result.append((String(part), URL(fileURLWithPath: current, isDirectory: true)))
        }
        return result
    }

    // MARK: - 탐색

    func open(_ url: URL) {
        let target = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "폴더가 없습니다: \(target.path)"
            return
        }
        directory = target
        refresh()
    }

    func goUp() {
        guard directory.path != "/" else { return }
        open(URL(fileURLWithPath: (directory.path as NSString).deletingLastPathComponent, isDirectory: true))
    }

    func refresh() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [])
            entries = urls.compactMap { url -> LocalEntry? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let hidden = url.lastPathComponent.hasPrefix(".") || (values?.isHidden ?? false)
                if hidden && !showHidden { return nil }
                var isDirectory = values?.isDirectory ?? false
                let isSymlink = values?.isSymbolicLink ?? false
                if isSymlink {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) { isDirectory = isDir.boolValue }
                }
                return LocalEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    isSymlink: isSymlink,
                    size: UInt64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = "폴더를 읽을 수 없습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - 변경

    func makeFolder(named name: String) {
        guard let name = RemoteBrowser.validName(name) else { return }
        perform { try FileManager.default.createDirectory(at: self.directory.appendingPathComponent(name), withIntermediateDirectories: false) }
    }

    func rename(_ entry: LocalEntry, to name: String) {
        guard let name = RemoteBrowser.validName(name), name != entry.name else { return }
        perform { try FileManager.default.moveItem(at: entry.url, to: entry.url.deletingLastPathComponent().appendingPathComponent(name)) }
    }

    /// 휴지통으로 옮긴다 (되돌릴 수 있게)
    func moveToTrash(_ items: [LocalEntry]) {
        perform {
            for item in items { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
        }
    }

    /// 다른 곳의 파일을 지금 폴더로 복사한다. 같은 이름이 있으면 번호를 붙인다.
    @discardableResult
    func copyIn(_ urls: [URL]) -> [URL] {
        var copied: [URL] = []
        perform {
            for url in urls {
                // 이미 이 폴더에 있는 파일이면 건너뛴다 (같은 칸 안에서 끌어 놓은 경우)
                if url.deletingLastPathComponent().standardizedFileURL == self.directory { continue }
                let target = RemoteBrowser.uniqueURL(self.directory.appendingPathComponent(url.lastPathComponent))
                try FileManager.default.copyItem(at: url, to: target)
                copied.append(target)
            }
        }
        return copied
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            refresh()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }
}
