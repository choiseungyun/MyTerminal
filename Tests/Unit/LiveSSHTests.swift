import AppKit
import SwiftUI
import XCTest
@testable import MyTerminal

/// 실제 sshd 로 끝까지 확인하는 통합 테스트 (평소에는 건너뛴다).
///
/// 이 Mac 에만 열리는 시험용 sshd(127.0.0.1:2222)와 시험용 키를 준비한 폴더를 환경 변수로 넘기면 동작한다:
///   MYTERM_LIVE_DIR=<폴더>  (userkey, ssh_config 가 들어 있어야 함)
///   xcodebuild test ... TEST_RUNNER_MYTERM_LIVE_DIR=<폴더>
/// ssh_config 는 사용자의 ~/.ssh 설정·known_hosts 를 건드리지 않도록 시험 전용 값만 쓴다.
/// 끝나면 이 테스트가 만든 연결 재사용 연결만 닫는다 (사용자가 쓰는 다른 연결은 건드리지 않는다).
@MainActor
final class LiveSSHTests: XCTestCase {
    private var dir: URL!
    private var config: String { dir.appendingPathComponent("ssh_config").path }
    private var key: String { dir.appendingPathComponent("userkey").path }
    private var user: String { NSUserName() }
    private var workDir: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MYTERM_LIVE_DIR"] else {
            throw XCTSkip("시험용 sshd 가 없어 건너뜀 (MYTERM_LIVE_DIR)")
        }
        dir = URL(fileURLWithPath: path)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        workDir = URL(fileURLWithPath: String(cString: realpath(temp.path, nil)))
    }

    override func tearDown() async throws {
        if dir != nil { closeMultiplex() }
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// 시험용 서버 접속 인자 (빠른 연결 형식)
    private var quickArguments: String { "-F \(config) -p 2222 -i \(key) \(user)@127.0.0.1" }

    private func host(_ name: String, jump: SSHHost? = nil) -> SSHHost {
        var host = SSHHost()
        host.name = name
        host.hostname = "127.0.0.1"
        host.port = 2222
        host.user = user
        host.identityFile = key
        host.jumpHostID = jump?.id
        return host
    }

    /// 시험이 만든 연결 재사용 연결만 닫는다
    private func closeMultiplex() {
        _ = run(["-F", config, "-O", "exit", "-o", "ControlPath=\(SSHMultiplex.directory)/%C", "-p", "2222", "\(user)@127.0.0.1"])
    }

    @discardableResult
    private func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }

    /// 경유 ssh(ProxyCommand)도 시험 전용 설정을 쓰게 한다 (사용자 known_hosts 를 건드리지 않기 위해)
    private func isolated(_ arguments: [String]) -> [String] {
        arguments.map { $0.replacingOccurrences(of: "ProxyCommand=ssh ", with: "ProxyCommand=ssh -F \(config) ") }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    // MARK: 점프 호스트

    /// 저장된 호스트를 경유(1단계·2단계)해 실제로 접속한다
    func testJumpHostThroughSavedHosts() {
        let bastion = host("bastion")
        let middle = host("middle", jump: bastion)
        let inner = host("inner", jump: middle)
        let hosts = [bastion, middle, inner]
        let resolve: SSHCommand.HostResolver = { id in hosts.first { $0.id == id } }

        let one = run(["-F", config] + isolated(SSHCommand.arguments(for: middle, resolve: resolve)) + ["echo", "jump1-ok"])
        XCTAssertEqual(one.status, 0, one.output)
        XCTAssertTrue(one.output.contains("jump1-ok"), one.output)

        let two = run(["-F", config] + isolated(SSHCommand.arguments(for: inner, resolve: resolve)) + ["echo", "jump2-ok"])
        XCTAssertEqual(two.status, 0, two.output)
        XCTAssertTrue(two.output.contains("jump2-ok"), two.output)
    }

    /// "접속 후 실행할 명령"
    func testRemoteCommandRunsAfterLogin() {
        var target = host("target")
        target.remoteCommand = "echo remote-command-ok"
        let launch = SSHCommand.launch(for: target, resolve: { _ in nil })
        let result = run(["-F", config] + launch.terminalArguments)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("remote-command-ok"), result.output)
    }

    // MARK: SFTP

    /// 실제 ssh(연결 재사용 포함) 위의 SFTP: 목록, 올리기, 받기(이중 확장자), 폴더·이름 바꾸기·삭제
    func testSFTPOverRealSSH() async throws {
        let remote = workDir.appendingPathComponent("remote")
        let local = workDir.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("dump".utf8).write(to: remote.appendingPathComponent("db_20261114.sql.gz"))

        let browser = RemoteBrowser(launch: SSHCommand.launch(for: QuickConnectTarget(quickArguments)!))
        await browser.connectIfNeeded()
        XCTAssertEqual(browser.state, .connected)
        await browser.open(remote.path)
        XCTAssertEqual(browser.entries.map(\.name), ["db_20261114.sql.gz"])

        // 올리기
        let upload = local.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: upload)
        await browser.upload([upload])
        await waitUntil { FileManager.default.fileExists(atPath: remote.appendingPathComponent("notes.txt").path) }
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("notes.txt"), encoding: .utf8), "hello")

        // 받기 (끌어 놓기와 같은 경로: 원래 이름 그대로)
        let dump = try XCTUnwrap(browser.entries.first { $0.name == "db_20261114.sql.gz" })
        await browser.download([dump], to: local)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("db_20261114.sql.gz").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("db_20261114.sql.gz.gz").path))

        // 폴더·이름 바꾸기·삭제
        await browser.makeFolder(named: "backup")
        let notes = try XCTUnwrap(browser.entries.first { $0.name == "notes.txt" })
        await browser.rename(notes, to: "notes-2.txt")
        XCTAssertEqual(Set(browser.entries.map(\.name)), ["backup", "db_20261114.sql.gz", "notes-2.txt"])
        await browser.delete(browser.entries.filter { $0.name != "db_20261114.sql.gz" })
        XCTAssertEqual(browser.entries.map(\.name), ["db_20261114.sql.gz"])
        XCTAssertTrue(browser.transfers.allSatisfy { $0.state == .done }, "\(browser.transfers)")

        browser.disconnect()
    }

    /// 원격 편집: 실제 ssh 위에서 받기 → 고치기 → 자동 올리기 → 충돌 감지
    func testRemoteEditOverRealSSH() async throws {
        let remote = workDir.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let serverFile = remote.appendingPathComponent("app.conf")
        try "port=80\n".write(to: serverFile, atomically: false, encoding: .utf8)

        let connection = try await SFTPConnection.open(SSHCommand.launch(for: QuickConnectTarget(quickArguments)!))
        defer { connection.close() }
        let client = connection.client
        let editor = RemoteEditor(client: { client }, workDirectory: workDir.appendingPathComponent("edit")) { _, _ in }
        editor.debounce = 50_000_000
        defer { editor.stopAll() }

        let listed = try await client.list(remote.path)
        let entry = try XCTUnwrap(listed.first { $0.name == "app.conf" })
        try await editor.edit(entry)
        let localFile = editor.files[0].localURL

        // 고쳐서 저장 → 서버 반영 (여러 번)
        for port in [8080, 9090] {
            try "port=\(port)\n".write(to: localFile, atomically: false, encoding: .utf8)
            await waitUntil { (try? String(contentsOf: serverFile, encoding: .utf8)) == "port=\(port)\n" }
            XCTAssertEqual(try String(contentsOf: serverFile, encoding: .utf8), "port=\(port)\n")
        }

        // 서버에서 따로 바뀐 뒤 저장 → 충돌
        try "port=1\n".write(to: serverFile, atomically: false, encoding: .utf8)
        try "port=2\n".write(to: localFile, atomically: false, encoding: .utf8)
        await waitUntil { if case .conflict = editor.files[0].state { return true }; return false }
        guard case .conflict = editor.files[0].state else { return XCTFail("충돌로 표시되어야 한다: \(editor.files[0].state)") }
        XCTAssertEqual(try String(contentsOf: serverFile, encoding: .utf8), "port=1\n", "충돌이면 덮어쓰지 않는다")

        // 덮어쓰기 버튼
        await editor.upload(editor.files[0].id, force: true)
        XCTAssertEqual(try String(contentsOf: serverFile, encoding: .utf8), "port=2\n")

        // 같은 초 안에 같은 크기로 서버가 바뀐 경우도 충돌 (작은 파일은 내용 비교)
        await waitUntil { if case .synced = editor.files[0].state { return true }; return false }
        try "port=3\n".write(to: serverFile, atomically: false, encoding: .utf8)
        try "port=4\n".write(to: localFile, atomically: false, encoding: .utf8)
        await waitUntil { if case .conflict = editor.files[0].state { return true }; return false }
        guard case .conflict = editor.files[0].state else { return XCTFail("같은 크기 변경도 충돌: \(editor.files[0].state)") }
        XCTAssertEqual(try String(contentsOf: serverFile, encoding: .utf8), "port=3\n")
    }

    // MARK: 터미널 접속과 접속 이력

    /// 실제 SSH 터미널: 접속 중 표시 → exit → 화면 닫힘, 이력에 끝 시각
    func testTerminalSessionAndHistory() async throws {
        let store = WorkspaceStore.forTesting()
        store.connect(QuickConnectTarget(quickArguments)!)
        let tab = try XCTUnwrap(store.currentTab)
        let pane = tab.panes[0]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TerminalTabView(tab: tab).environmentObject(store))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let record = try XCTUnwrap(store.history.records.first)
        XCTAssertTrue(store.isOpen(record), "열려 있으면 접속 중")
        XCTAssertEqual(record.user, user)

        // 원격 셸 프롬프트가 뜰 때까지
        await waitUntil(15) { pane.view.visibleText().contains("$") || pane.view.visibleText().contains("%") }
        pane.view.sendText("exit")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            if type == .keyDown { pane.view.keyDown(with: event) } else { pane.view.keyUp(with: event) }
        }

        await waitUntil(10) { store.tabs.isEmpty }
        XCTAssertTrue(store.tabs.isEmpty, "정상 로그아웃이면 탭이 닫힌다:\n\(pane.view.visibleText())")
        let ended = store.history.records.first { $0.id == record.id }
        XCTAssertNotNil(ended?.endedAt, "이력에 끝 시각")
        XCTAssertFalse(store.isOpen(ended!))
    }
}
