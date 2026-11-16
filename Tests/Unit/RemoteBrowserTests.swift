import SwiftUI
import XCTest
@testable import MyTerminal

/// 원격 탐색기 모델을 로컬 sftp-server 에 연결해 검사한다.
@MainActor
final class RemoteBrowserTests: XCTestCase {
    private var root: URL!
    private var browser: RemoteBrowser!

    override func setUp() async throws {
        // /var 는 /private/var 의 링크라 서버가 돌려주는 실제 경로(realpath)로 맞춘다.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("browser-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: realpath(temp.path, nil)))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("remote"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("local"), withIntermediateDirectories: true)

        browser = RemoteBrowser(launch: SSHLaunch(title: "test", arguments: ["test"])) { _ in
            let client = try await SFTPClient(transport: ProcessTransport(executable: "/usr/libexec/sftp-server", arguments: []))
            return (client, client.close)
        }
        await browser.connectIfNeeded()
        XCTAssertEqual(browser.state, .connected)
        await browser.open(remote)
    }

    override func tearDown() async throws {
        browser?.disconnect()
        try? FileManager.default.removeItem(at: root)
    }

    private var remote: String { root.appendingPathComponent("remote").path }
    private var local: URL { root.appendingPathComponent("local") }

    func testListSortsFoldersFirstAndHidesDotFiles() async throws {
        try Data().write(to: URL(fileURLWithPath: remote + "/b.txt"))
        try Data().write(to: URL(fileURLWithPath: remote + "/.hidden"))
        try FileManager.default.createDirectory(atPath: remote + "/z-folder", withIntermediateDirectories: true)
        await browser.refresh()

        XCTAssertEqual(browser.entries.map(\.name), ["z-folder", "b.txt"])
        browser.showHidden = true
        XCTAssertEqual(browser.entries.map(\.name), ["z-folder", ".hidden", "b.txt"])
    }

    /// 회귀: 서버 칸 → 이 Mac 칸으로 끌어 놓으면 원래 이름(a.sql.gz) 그대로 받는다 (시스템 파일 약속을 거치지 않음)
    func testInAppDragDownloadsWithExactName() async throws {
        try Data("dump".utf8).write(to: URL(fileURLWithPath: remote + "/backup_20261114_030001.sql.gz"))
        await browser.refresh()
        let entry = try XCTUnwrap(browser.entries.first { $0.name == "backup_20261114_030001.sql.gz" })

        SFTPInAppDrag.begin(browser: browser, entries: [entry])
        let provider = NSItemProvider()
        provider.suggestedName = "backup_20261114_030001.sql.gz.gz"   // 시스템이 덧붙인 이름이라도
        let drag = try XCTUnwrap(SFTPInAppDrag.take(for: [provider]))
        XCTAssertNil(SFTPInAppDrag.take(for: [provider]), "한 번 쓰면 지운다")

        await drag.browser.download(drag.entries, to: local)
        let names = try FileManager.default.contentsOfDirectory(atPath: local.path)
        XCTAssertEqual(names, ["backup_20261114_030001.sql.gz"])
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent(names[0]), encoding: .utf8), "dump")
        XCTAssertEqual(browser.transfers.last?.state, .done, "전송 목록에 보인다")
    }

    /// Finder 파일·다른 이름·오래된 기록에는 쓰지 않는다
    func testInAppDragIgnoresUnrelatedDrops() async throws {
        let entry = SFTPEntry(name: "a.log", path: remote + "/a.log", size: 1, permissions: 0o644, modified: nil, isDirectory: false, isSymlink: false)

        SFTPInAppDrag.begin(browser: browser, entries: [entry])
        let finder = NSItemProvider(object: URL(fileURLWithPath: "/tmp/a.log") as NSURL)
        XCTAssertNil(SFTPInAppDrag.take(for: [finder]), "Finder 에서 온 파일")

        let other = NSItemProvider()
        other.suggestedName = "b.txt"
        XCTAssertNil(SFTPInAppDrag.take(for: [other]), "다른 파일")

        SFTPInAppDrag.begin(browser: browser, entries: [entry], now: Date().addingTimeInterval(-600))
        let same = NSItemProvider()
        same.suggestedName = "a.log"
        XCTAssertNil(SFTPInAppDrag.take(for: [same]), "오래된 기록")
        SFTPInAppDrag.reset()
    }

    /// 회귀: 서버 칸의 폴더를 이 Mac 칸으로 끌어도 받아지지 않음 (폴더는 끌 수 없었다)
    func testInAppDragDownloadsFolder() async throws {
        try FileManager.default.createDirectory(atPath: remote + "/site/css", withIntermediateDirectories: true)
        try Data("<html>".utf8).write(to: URL(fileURLWithPath: remote + "/site/index.html"))
        try Data("body{}".utf8).write(to: URL(fileURLWithPath: remote + "/site/css/a.css"))
        await browser.refresh()
        let folder = try XCTUnwrap(browser.entries.first { $0.name == "site" })

        SFTPInAppDrag.begin(browser: browser, entries: [folder])
        let provider = NSItemProvider()
        provider.suggestedName = "site"
        let drag = try XCTUnwrap(SFTPInAppDrag.take(for: [provider]))
        await drag.browser.download(drag.entries, to: local)

        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("site/css/a.css"), encoding: .utf8), "body{}")
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("site/index.html"), encoding: .utf8), "<html>")
        XCTAssertEqual(browser.transfers.count, 1, "폴더 하나는 전송 하나")
        XCTAssertEqual(browser.transfers.last?.doneBytes, 12)
        SFTPInAppDrag.reset()
    }

    /// 회귀: 앱 안에 한 번 놓았는데 같은 파일이 두 번 받아짐 (놓은 폴더 + 시스템 요청으로 임시 폴더)
    func testPromiseIsSkippedOnlyForDragsHandledInApp() throws {
        let entry = SFTPEntry(name: "a.dmg", path: remote + "/a.dmg", size: 1, permissions: 0o644, modified: nil, isDirectory: false, isSymlink: false)

        let inApp = SFTPInAppDrag.begin(browser: browser, entries: [entry])
        XCTAssertFalse(SFTPInAppDrag.shouldSkipPromise(for: inApp), "놓기 전에는 모른다")
        let provider = NSItemProvider()
        provider.suggestedName = "a.dmg"
        XCTAssertNotNil(SFTPInAppDrag.take(for: [provider]))
        XCTAssertTrue(SFTPInAppDrag.shouldSkipPromise(for: inApp), "앱 안에서 받았으니 시스템 요청은 건너뛴다")

        let toFinder = SFTPInAppDrag.begin(browser: browser, entries: [entry])
        XCTAssertFalse(SFTPInAppDrag.shouldSkipPromise(for: toFinder), "Finder 로 끈 것은 받아야 한다")
        SFTPInAppDrag.reset()
    }

    func testNavigationAndPathComponents() async throws {
        try FileManager.default.createDirectory(atPath: remote + "/a/b", withIntermediateDirectories: true)
        await browser.open(remote + "/a/b")
        XCTAssertEqual(browser.path, remote + "/a/b")
        XCTAssertEqual(browser.pathComponents.last?.name, "b")
        XCTAssertEqual(browser.pathComponents.first?.path, "/")
        await browser.goUp()
        XCTAssertEqual(browser.path, remote + "/a")
    }

    func testUploadFolderRecursively() async throws {
        let project = local.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("main".utf8).write(to: project.appendingPathComponent("src/main.c"))
        try Data("readme".utf8).write(to: project.appendingPathComponent("README"))

        await browser.upload([project])

        XCTAssertEqual(try String(contentsOfFile: remote + "/project/src/main.c", encoding: .utf8), "main")
        XCTAssertEqual(try String(contentsOfFile: remote + "/project/README", encoding: .utf8), "readme")
        XCTAssertEqual(browser.transfers.last?.state, .done)
        XCTAssertEqual(browser.transfers.last?.doneBytes, 10)
        XCTAssertEqual(browser.entries.map(\.name), ["project"], "올린 뒤 목록 갱신")
    }

    func testDownloadFileAndFolderWithUniqueNames() async throws {
        try FileManager.default.createDirectory(atPath: remote + "/logs/old", withIntermediateDirectories: true)
        try Data("a".utf8).write(to: URL(fileURLWithPath: remote + "/logs/app.log"))
        try Data("b".utf8).write(to: URL(fileURLWithPath: remote + "/logs/old/1.log"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: remote + "/note.txt"))
        try Data("existing".utf8).write(to: local.appendingPathComponent("note.txt"))
        await browser.refresh()

        await browser.download(browser.entries, to: local)

        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("logs/old/1.log"), encoding: .utf8), "b")
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("note 2.txt"), encoding: .utf8), "x", "같은 이름이 있으면 번호를 붙인다")
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("note.txt"), encoding: .utf8), "existing")
        XCTAssertTrue(browser.transfers.allSatisfy { $0.state == .done })
    }

    func testMakeRenameDelete() async throws {
        await browser.makeFolder(named: "new")
        XCTAssertEqual(browser.entries.map(\.name), ["new"])
        await browser.rename(browser.entries[0], to: "renamed")
        XCTAssertEqual(browser.entries.map(\.name), ["renamed"])
        try Data().write(to: URL(fileURLWithPath: remote + "/renamed/inside"))
        await browser.delete(browser.entries)
        XCTAssertTrue(browser.entries.isEmpty)
        XCTAssertNil(browser.errorMessage)
    }

    func testInvalidNamesAreIgnored() {
        for bad in ["", "  ", ".", "..", "a/b"] { XCTAssertNil(RemoteBrowser.validName(bad), bad) }
        XCTAssertEqual(RemoteBrowser.validName(" ok "), "ok")
    }

    func testErrorIsShownWithoutDisconnecting() async {
        await browser.open(remote + "/missing")
        XCTAssertEqual(browser.errorMessage, "파일이나 폴더가 없습니다.")
        XCTAssertEqual(browser.state, .connected)
        XCTAssertEqual(browser.path, remote, "실패하면 원래 폴더에 머문다")
    }

    func testDownloadToTemporaryForDragOut() async throws {
        try Data("drag".utf8).write(to: URL(fileURLWithPath: remote + "/d.txt"))
        await browser.refresh()
        let url = try await browser.downloadToTemporary(browser.entries[0])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "drag")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testDownloadFolderToTemporaryForDragOut() async throws {
        try FileManager.default.createDirectory(atPath: remote + "/dir/sub", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: remote + "/dir/sub/x.txt"))
        await browser.refresh()
        let url = try await browser.downloadToTemporary(browser.entries[0])
        XCTAssertEqual(url.lastPathComponent, "dir")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("sub/x.txt"), encoding: .utf8), "x")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testRemovesLeftoverDragTemporaries() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: local.appendingPathComponent("MyTerminal-drag-1/a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: local.appendingPathComponent("MyTerminal-drag-2"), withIntermediateDirectories: true)
        try fm.createDirectory(at: local.appendingPathComponent("keep"), withIntermediateDirectories: true)
        XCTAssertEqual(RemoteBrowser.removeDragTemporaries(in: local), 2)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: local.path), ["keep"])
    }
}

/// 파일 패널을 실제 창에 띄워, 화면에 나타나면 스스로 연결하고 목록을 불러오는지 검사한다.
@MainActor
final class FileBrowserPanelTests: XCTestCase {
    func testPanelConnectsAndListsWhenShown() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("panel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = String(cString: realpath(temp.path, nil))
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/hello.txt"))

        let browser = RemoteBrowser(launch: SSHLaunch(title: "test", arguments: ["test"])) { _ in
            let client = try await SFTPClient(transport: ProcessTransport(executable: "/usr/libexec/sftp-server", arguments: []))
            return (client, client.close)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FileBrowserPanel(browser: browser, title: "test"))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // .task 가 연결을 시작한다
        let deadline = Date().addingTimeInterval(5)
        while browser.state != .connected && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(browser.state, .connected)

        await browser.open(root)
        XCTAssertEqual(browser.entries.map(\.name), ["hello.txt"])
        browser.disconnect()
    }
}
