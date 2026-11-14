import XCTest
@testable import MyTerminal

/// 원격 편집: 로컬 sftp-server 를 서버로, 편집기 대신 파일을 직접 고쳐서 검사한다.
@MainActor
final class RemoteEditorTests: XCTestCase {
    private var root: URL!
    private var client: SFTPClient!
    private var editor: RemoteEditor!
    private var opened: [URL] = []

    override func setUp() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("edit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("server"), withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: realpath(temp.path, nil)))
        client = try await SFTPClient(transport: ProcessTransport(executable: "/usr/libexec/sftp-server", arguments: []))
        let client = self.client
        editor = RemoteEditor(client: { client }, workDirectory: root.appendingPathComponent("work")) { [weak self] url, _ in
            self?.opened.append(url)
        }
        editor.debounce = 50_000_000
    }

    override func tearDown() async throws {
        editor?.stopAll()
        client?.close()
        try? FileManager.default.removeItem(at: root)
    }

    private var serverFile: URL { root.appendingPathComponent("server/app.conf") }

    private func entry() async throws -> SFTPEntry {
        try await client.list(root.appendingPathComponent("server").path).first { $0.name == "app.conf" }!
    }

    /// 조건이 될 때까지 기다린다 (파일 감시·지연 업로드)
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func serverText() -> String { (try? String(contentsOf: serverFile, encoding: .utf8)) ?? "" }

    /// 회귀: SFTP 수정 시각은 초 단위라 같은 초 안에 서버에서 바뀐 것을 놓쳐 서버 내용을 덮어썼다 → 크기도 비교
    func testConflictDetectedWithinSameSecond() async throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let file = RemoteEditor.EditingFile(
            name: "a", remotePath: "/a", localURL: URL(fileURLWithPath: "/tmp/a"),
            remoteModified: stamp, remoteSize: 10, digest: "", state: .synced(nil))
        XCTAssertFalse(RemoteEditor.changedOnServer(file, SFTPAttributes(size: 10, permissions: nil, modified: stamp)))
        XCTAssertTrue(RemoteEditor.changedOnServer(file, SFTPAttributes(size: 7, permissions: nil, modified: stamp)), "같은 초, 다른 크기")
        XCTAssertTrue(RemoteEditor.changedOnServer(file, SFTPAttributes(size: 10, permissions: nil, modified: stamp.addingTimeInterval(1))))
    }

    func testEditDownloadsAndOpens() async throws {
        try "port=80\n".write(to: serverFile, atomically: true, encoding: .utf8)
        try await editor.edit(try await entry())

        XCTAssertEqual(editor.files.count, 1)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.lastPathComponent, "app.conf", "편집기에 원래 파일 이름으로 보인다")
        XCTAssertEqual(try String(contentsOf: editor.files[0].localURL, encoding: .utf8), "port=80\n")
    }

    func testSavingUploadsAutomatically() async throws {
        try "port=80\n".write(to: serverFile, atomically: false, encoding: .utf8)
        try await editor.edit(try await entry())
        let local = editor.files[0].localURL

        // 제자리 저장
        let handle = try FileHandle(forWritingTo: local)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("port=8080\n".utf8))
        try handle.close()
        await waitUntil { self.serverText() == "port=8080\n" }
        XCTAssertEqual(serverText(), "port=8080\n")
        await waitUntil { if case .synced(let d) = self.editor.files[0].state { return d != nil } else { return false } }
        if case .synced(let date) = editor.files[0].state { XCTAssertNotNil(date) } else { XCTFail("\(editor.files[0].state)") }
    }

    func testAtomicSaveIsAlsoDetected() async throws {
        try "a\n".write(to: serverFile, atomically: false, encoding: .utf8)
        try await editor.edit(try await entry())
        let local = editor.files[0].localURL

        // 편집기처럼 새 파일에 쓰고 바꿔치기, 두 번 연달아
        try "b\n".write(to: local, atomically: true, encoding: .utf8)
        await waitUntil { self.serverText() == "b\n" }
        try await Task.sleep(nanoseconds: 300_000_000)
        try "c\n".write(to: local, atomically: true, encoding: .utf8)
        await waitUntil { self.serverText() == "c\n" }
        XCTAssertEqual(serverText(), "c\n")
    }

    func testConflictWhenServerChangedMeanwhile() async throws {
        try "v1\n".write(to: serverFile, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: serverFile.path)
        try await editor.edit(try await entry())
        let id = editor.files[0].id
        let local = editor.files[0].localURL

        // 다른 사람이 서버 파일을 고침
        try "server change\n".write(to: serverFile, atomically: false, encoding: .utf8)
        // 내가 로컬에서 저장
        try "my change\n".write(to: local, atomically: false, encoding: .utf8)
        await waitUntil { self.editor.files.first?.state == .conflict }
        XCTAssertEqual(editor.files[0].state, .conflict)
        XCTAssertEqual(serverText(), "server change\n", "충돌이면 덮어쓰지 않는다")

        // 서버 버전 받기
        await editor.reloadFromServer(id)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "server change\n")

        // 다시 고치면 이번엔 올라간다 (기준 시각이 갱신됨)
        try "merged\n".write(to: local, atomically: false, encoding: .utf8)
        await waitUntil { self.serverText() == "merged\n" }
        XCTAssertEqual(serverText(), "merged\n")
    }

    func testForceOverwrite() async throws {
        try "v1\n".write(to: serverFile, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: serverFile.path)
        try await editor.edit(try await entry())
        let id = editor.files[0].id
        try "server\n".write(to: serverFile, atomically: false, encoding: .utf8)
        try "mine\n".write(to: editor.files[0].localURL, atomically: false, encoding: .utf8)
        await waitUntil { self.editor.files.first?.state == .conflict }

        await editor.upload(id, force: true)
        XCTAssertEqual(serverText(), "mine\n")
    }

    func testStopEditingRemovesLocalCopyAndOpensAgain() async throws {
        try "x".write(to: serverFile, atomically: false, encoding: .utf8)
        let e = try await entry()
        try await editor.edit(e)
        try await editor.edit(e)
        XCTAssertEqual(editor.files.count, 1, "같은 파일은 다시 열기만 한다")
        XCTAssertEqual(opened.count, 2)

        let local = editor.files[0].localURL
        editor.stopEditing(editor.files[0].id)
        XCTAssertTrue(editor.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
    }
}
