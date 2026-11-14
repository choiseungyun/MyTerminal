import XCTest
@testable import MyTerminal

@MainActor
final class LocalBrowserTests: XCTestCase {
    private var root: URL!
    private var browser: LocalBrowser!

    override func setUp() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("local-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: realpath(temp.path, nil)))
        browser = LocalBrowser(directory: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testListSortsFoldersFirstAndHidesDotFiles() throws {
        try Data().write(to: root.appendingPathComponent("b.txt"))
        try Data().write(to: root.appendingPathComponent(".env"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("z"), withIntermediateDirectories: true)
        browser.refresh()
        XCTAssertEqual(browser.entries.map(\.name), ["z", "b.txt"])
        browser.showHidden = true
        XCTAssertEqual(browser.entries.map(\.name), ["z", ".env", "b.txt"])
    }

    func testNavigation() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        browser.open(root.appendingPathComponent("a/b"))
        XCTAssertEqual(browser.path, root.appendingPathComponent("a/b").standardizedFileURL.path)
        XCTAssertEqual(browser.pathComponents.last?.name, "b")
        XCTAssertEqual(browser.pathComponents.first?.name, "/")
        browser.goUp()
        XCTAssertEqual(browser.path, root.appendingPathComponent("a").standardizedFileURL.path)

        browser.open(root.appendingPathComponent("missing"))
        XCTAssertNotNil(browser.errorMessage)
        XCTAssertEqual(browser.path, root.appendingPathComponent("a").standardizedFileURL.path, "없는 폴더면 그대로")
    }

    /// 회귀: 홈 폴더(끝에 / 가 붙은 URL)와 "/" 에서 경로 조각 계산이 끝나지 않아 SFTP 탭이 멈췄다.
    func testPathComponentsTerminateForHomeAndRoot() {
        let home = LocalBrowser(directory: FileManager.default.homeDirectoryForCurrentUser)
        let parts = home.pathComponents
        XCTAssertEqual(parts.first?.name, "/")
        XCTAssertEqual(parts.last?.url.standardizedFileURL.path, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        XCTAssertEqual(parts.count, FileManager.default.homeDirectoryForCurrentUser.path.split(separator: "/").count + 1)

        let root = LocalBrowser(directory: URL(fileURLWithPath: "/"))
        XCTAssertEqual(root.pathComponents.map(\.name), ["/"])
        root.goUp()
        XCTAssertEqual(root.path, "/", "/ 에서 위로 가도 그대로")

        let withSlash = LocalBrowser(directory: URL(string: "file:///usr/bin/")!)
        XCTAssertEqual(withSlash.pathComponents.map(\.name), ["/", "usr", "bin"])
        withSlash.goUp()
        XCTAssertEqual(withSlash.path, "/usr")
    }

    func testMakeRenameTrash() throws {
        browser.makeFolder(named: "new")
        XCTAssertEqual(browser.entries.map(\.name), ["new"])
        browser.rename(browser.entries[0], to: "renamed")
        XCTAssertEqual(browser.entries.map(\.name), ["renamed"])
        browser.moveToTrash(browser.entries)
        XCTAssertTrue(browser.entries.isEmpty)
    }

    func testCopyInUsesUniqueNamesAndSkipsSameFolder() throws {
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: root.appendingPathComponent("f.txt"))
        browser.refresh()

        let copied = browser.copyIn([other.appendingPathComponent("f.txt"), root.appendingPathComponent("f.txt")])
        XCTAssertEqual(copied.map(\.lastPathComponent), ["f 2.txt"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("f.txt"), encoding: .utf8), "old")
    }
}

@MainActor
final class SFTPTabTests: XCTestCase {
    func testOpenAndCloseRemote() {
        let store = WorkspaceStore.forTesting()
        var host = SSHHost()
        host.hostname = "files.example.com"
        host.user = "deploy"

        XCTAssertNil(store.sftpRemote)
        store.openSFTP(host)
        XCTAssertEqual(store.selectedTab, .sftp)
        XCTAssertEqual(store.sftpRemote?.launch.arguments, ["deploy@files.example.com"])
        XCTAssertEqual(store.sftpRemote?.state, .idle, "화면에 나타나기 전에는 연결하지 않는다")

        store.openSFTP(QuickConnectTarget("ops@other")!)
        XCTAssertEqual(store.sftpRemote?.launch.arguments, ["ops@other"], "다른 호스트로 바꿀 수 있다")

        store.closeSFTPRemote()
        XCTAssertNil(store.sftpRemote)
        XCTAssertEqual(store.sftpLocal.path, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
    }
}
