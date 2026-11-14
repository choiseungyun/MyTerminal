import XCTest
@testable import MyTerminal

final class AskpassServerTests: XCTestCase {
    private var server: AskpassServer!
    private var directory: URL!
    private let hostID = UUID()
    private let secret = "s3cr3t 'with' spaces"

    override func setUpWithError() throws {
        // 소켓 경로 길이 제한(104바이트) 때문에 짧은 폴더 이름을 쓴다.
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mt-\(UUID().uuidString.prefix(6))")
        let hostID = self.hostID, secret = self.secret
        server = AskpassServer(directory: directory) { $0 == hostID ? secret : nil }
        XCTAssertTrue(server.startIfNeeded())
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// 도우미 스크립트를 ssh 처럼 실행하고 표준 출력을 돌려준다.
    private func runScript(prompt: String, token: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [server.scriptPath, prompt]
        process.environment = [
            "MYTERM_ASKPASS_TOKEN": token,
            "MYTERM_ASKPASS_SOCKET": server.socketPath,
            "MYTERM_ASKPASS_DIR": directory.path,
            "PATH": "/usr/bin:/bin",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func register() -> String {
        server.register(.init(hostID: hostID, names: ["web-01.example.com", "web01"]))
    }

    func testScriptReceivesSavedPassword() throws {
        let output = try runScript(prompt: "deploy@web-01.example.com's password: ", token: register())
        XCTAssertEqual(output, secret + "\n")
    }

    func testSecondAttemptDoesNotResendSamePassword() throws {
        let token = register()
        XCTAssertEqual(try runScript(prompt: "deploy@web01's password: ", token: token), secret + "\n")
        // 같은 ssh(같은 부모 프로세스)가 다시 물으면 저장된 비밀번호가 틀린 것 → 터미널에서 묻는다 (여기선 tty 가 없어 빈 값)
        XCTAssertNotEqual(try runScript(prompt: "deploy@web01's password: ", token: token), secret + "\n")
    }

    func testWrongTokenGetsNothing() throws {
        _ = register()
        XCTAssertNotEqual(try runScript(prompt: "deploy@web01's password: ", token: "bad-token"), secret + "\n")
    }

    func testOtherHostPromptGetsNothing() {
        // 점프 호스트 등 다른 서버가 묻는 비밀번호에는 주지 않는다
        let token = register()
        XCTAssertNil(server.password(token: token, prompt: "ops@bastion.example.com's password: "))
        XCTAssertEqual(server.password(token: token, prompt: "deploy@web01's password: "), secret)
    }

    func testUnregisteredTokenIsRejected() {
        let token = register()
        server.unregister(token)
        XCTAssertNil(server.password(token: token, prompt: "Password:"))
    }

    func testPromptMatching() {
        let names = ["web-01", "prod"]
        XCTAssertTrue(AskpassServer.prompt("deploy@web-01's password: ", matches: names))
        XCTAssertTrue(AskpassServer.prompt("(admin@prod) Password:", matches: names))
        XCTAssertTrue(AskpassServer.prompt("Password:", matches: names))
        XCTAssertFalse(AskpassServer.prompt("ops@bastion's password: ", matches: names))
        XCTAssertFalse(AskpassServer.prompt("Are you sure you want to continue connecting (yes/no)?", matches: names))
        XCTAssertFalse(AskpassServer.prompt("Enter passphrase for key '/Users/me/.ssh/id':", matches: names))
    }

    func testEnvironmentOnlyForPasswordHosts() {
        var launch = SSHLaunch(title: "x", arguments: ["x"], hostID: hostID)
        XCTAssertNil(server.environment(for: launch))

        launch.usesSavedPassword = true
        let env = server.environment(for: launch)?.environment
        XCTAssertEqual(env?["SSH_ASKPASS"], server.scriptPath)
        XCTAssertEqual(env?["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(env?["MYTERM_ASKPASS_TOKEN"]?.count, 64)
    }

    func testSocketAndFolderArePrivate() throws {
        let fm = FileManager.default
        let dirMode = try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let sockMode = try fm.attributesOfItem(atPath: server.socketPath)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertEqual(sockMode, 0o600)
    }
}

final class KeychainTests: XCTestCase {
    func testSaveReadUpdateDelete() {
        let id = UUID()
        defer { Keychain.deletePassword(hostID: id) }

        XCTAssertNil(Keychain.password(hostID: id))
        XCTAssertTrue(Keychain.savePassword("첫 비밀번호", hostID: id))
        XCTAssertEqual(Keychain.password(hostID: id), "첫 비밀번호")
        XCTAssertTrue(Keychain.savePassword("바뀐 비밀번호", hostID: id))
        XCTAssertEqual(Keychain.password(hostID: id), "바뀐 비밀번호")
        XCTAssertTrue(Keychain.hasPassword(hostID: id))
        Keychain.deletePassword(hostID: id)
        XCTAssertNil(Keychain.password(hostID: id))
    }
}
