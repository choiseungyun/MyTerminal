import XCTest
@testable import MyTerminal

/// macOS 기본 sftp-server(로컬 파일 시스템)를 상대로 SFTP 클라이언트를 검사한다. ssh·서버가 필요 없다.
final class SFTPClientTests: XCTestCase {
    private var root: URL!
    private var client: SFTPClient!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-test-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = try ProcessTransport(executable: "/usr/libexec/sftp-server", arguments: [])
        client = try await SFTPClient(transport: transport)
    }

    override func tearDown() async throws {
        client?.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    func testRealpathAndExtensions() async throws {
        let home = try await client.realpath(".")
        XCTAssertTrue(home.hasPrefix("/"))
        XCTAssertNotNil(client.extensions["posix-rename@openssh.com"])
    }

    func testListShowsFilesFoldersAndSymlinks() async throws {
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: path("dir"))

        let entries = try await client.list(root.path).sorted { $0.name < $1.name }
        XCTAssertEqual(entries.map(\.name), ["a.txt", "dir", "link"])
        XCTAssertEqual(entries[0].size, 5)
        XCTAssertFalse(entries[0].isDirectory)
        XCTAssertNotNil(entries[0].modified)
        XCTAssertTrue(entries[1].isDirectory)
        XCTAssertTrue(entries[2].isSymlink)
        XCTAssertTrue(entries[2].isDirectory, "폴더를 가리키는 링크는 폴더로 본다")
        XCTAssertEqual(entries[0].path, path("a.txt"))
    }

    func testUploadDownloadRoundTrip() async throws {
        // 조각 크기의 배수가 아닌 크기 + 여러 조각 (동시 요청 경로 검사)
        var bytes = [UInt8](repeating: 0, count: 1_000_003)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        let source = root.appendingPathComponent("source.bin")
        try Data(bytes).write(to: source)

        var uploaded: UInt64 = 0
        try await client.upload(source, to: path("remote.bin")) { uploaded = $0 }
        XCTAssertEqual(uploaded, UInt64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote.bin")), Data(bytes))

        let target = root.appendingPathComponent("downloaded.bin")
        var downloaded: UInt64 = 0
        try await client.download(path("remote.bin"), to: target) { downloaded = $0 }
        XCTAssertEqual(downloaded, UInt64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: target), Data(bytes))
    }

    func testEmptyFile() async throws {
        let empty = root.appendingPathComponent("empty")
        try Data().write(to: empty)
        try await client.upload(empty, to: path("empty-remote"))
        let target = root.appendingPathComponent("empty-down")
        try await client.download(path("empty-remote"), to: target)
        XCTAssertEqual(try Data(contentsOf: target).count, 0)
    }

    func testUploadOverwritesExisting() async throws {
        try Data("long old content".utf8).write(to: root.appendingPathComponent("f"))
        let source = root.appendingPathComponent("new")
        try Data("new".utf8).write(to: source)
        try await client.upload(source, to: path("f"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("f"), encoding: .utf8), "new")
    }

    func testMkdirRenameRemove() async throws {
        try await client.mkdir(path("folder"))
        try Data("x".utf8).write(to: root.appendingPathComponent("folder/inner.txt"))
        try await client.rename(path("folder"), to: path("renamed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("renamed/inner.txt")))

        try await client.remove(path("renamed/inner.txt"))
        try await client.rmdir(path("renamed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("renamed")))
    }

    func testRenameReplacesExistingTarget() async throws {
        try Data("a".utf8).write(to: root.appendingPathComponent("a"))
        try Data("b".utf8).write(to: root.appendingPathComponent("b"))
        try await client.rename(path("a"), to: path("b"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b"), encoding: .utf8), "a")
    }

    func testRemoveRecursively() async throws {
        let nested = root.appendingPathComponent("tree/sub/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: nested.appendingPathComponent("f1"))
        try Data("2".utf8).write(to: root.appendingPathComponent("tree/f2"))
        try await client.removeRecursively(path("tree"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("tree")))
    }

    func testMissingPathError() async {
        do {
            _ = try await client.list(path("nope"))
            XCTFail("오류가 나야 함")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .status(code: SFTPError.noSuchFile, message: error.statusMessage))
            XCTAssertEqual(error.errorDescription, "파일이나 폴더가 없습니다.")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRequestsFailAfterConnectionLost() async throws {
        client.close()
        do {
            _ = try await client.realpath(".")
            XCTFail("오류가 나야 함")
        } catch let error as SFTPError {
            if case .connectionLost = error {} else { XCTFail("\(error)") }
        }
    }

    func testManyConcurrentRequests() async throws {
        for i in 0..<20 { try await client.mkdir(path("d\(i)")) }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<20 { group.addTask { try await self.client.list(self.path("d\(i)")).count } }
            for try await count in group { XCTAssertEqual(count, 0) }
        }
    }
}

private extension SFTPError {
    var statusMessage: String {
        if case .status(_, let message) = self { return message }
        return ""
    }
}

final class SFTPConnectionTests: XCTestCase {
    func testArgumentsUseSubsystemAndConnectionReuse() {
        let launch = SSHLaunch(title: "x", arguments: ["-p", "2222", "deploy@web-01"])
        let args = SFTPConnection.arguments(for: launch)
        XCTAssertEqual(args.first, "-s")
        XCTAssertEqual(args.last, "sftp")
        XCTAssertEqual(Array(args.suffix(4).prefix(3)), ["-p", "2222", "deploy@web-01"])
        XCTAssertTrue(args.contains("ControlMaster=auto"))
    }

    /// 실제 ssh 를 실행해 접속 실패를 알기 쉬운 문장으로 바꾸는지 확인한다 (서버 없이 가능한 경로)
    func testUnknownHostGivesFriendlyError() async {
        let launch = SSHLaunch(title: "x", arguments: ["-o", "ConnectTimeout=5", "no-such-host.invalid"])
        do {
            _ = try await SFTPConnection.open(launch)
            XCTFail("접속되면 안 됨")
        } catch {
            XCTAssertEqual(error.localizedDescription, "호스트 이름을 찾을 수 없습니다.")
        }
    }

    /// 회귀(2026-11-26, GitHub CI 에서 가끔): 프로세스가 오류 문구를 쓰고 바로 끝나도, 실패를 판단할 때 문구가 다 들어와 있다
    func testErrorTextIsCompleteAfterQuickExit() async throws {
        for _ in 0..<20 {
            let transport = try ProcessTransport(
                executable: "/bin/sh",
                arguments: ["-c", "echo 'ssh: Could not resolve hostname no-such-host.invalid: nodename nor servname provided' >&2; exit 255"])
            let text = await transport.errorTextAfterExit()
            XCTAssertTrue(text.contains("Could not resolve hostname"), "받은 문구: \(text.debugDescription)")
            transport.terminate()
        }
    }

    func testFriendlyErrorMapping() {
        let base = SFTPError.connectionLost("")
        let cases: [(String, String)] = [
            ("Host key verification failed.", "호스트 키 확인"),
            ("deploy@x: Permission denied (publickey).", "인증에 실패"),
            ("subsystem request failed on channel 0", "SFTP 를 사용할 수 없습니다"),
        ]
        for (stderr, expected) in cases {
            XCTAssertTrue(SFTPConnection.friendlyError(base, stderr: stderr).localizedDescription.contains(expected), stderr)
        }
        XCTAssertEqual(SFTPConnection.friendlyError(base, stderr: "something else") as? SFTPError, base)
    }
}
