import XCTest
@testable import MyTerminal

/// 점프 호스트(경유)와 접속 후 실행할 명령
final class JumpHostTests: XCTestCase {
    private func bastion() -> SSHHost {
        var h = SSHHost()
        h.name = "bastion"
        h.hostname = "203.0.113.10"
        h.user = "ubuntu"
        h.identityFile = "/Users/me/keys/cloud key.pem"
        return h
    }

    private func internalHost(via jump: SSHHost) -> SSHHost {
        var h = SSHHost()
        h.hostname = "192.0.2.44"
        h.user = "ubuntu"
        h.identityFile = "/Users/me/keys/cloud key.pem"
        h.jumpHostID = jump.id
        return h
    }

    // MARK: 입력 검증

    func testJumpHostValidation() {
        for ok in ["bastion", "ubuntu@1.2.3.4", "ubuntu@1.2.3.4:2222", "a@b,c@d:22", "user@[2001:db8::1]:22"] {
            XCTAssertTrue(HostForm.isValidJumpHost(ok), ok)
        }
        // 실제로 들어왔던 잘못된 값: 명령 전체
        for bad in ["ssh -i .ssh/inner-key.pem 192.0.2.44", "a b", "-i key host", "host;rm -rf ~"] {
            XCTAssertFalse(HostForm.isValidJumpHost(bad), bad)
        }
    }

    func testFormRejectsCommandInJumpField() {
        var form = HostForm(host: SSHHost())
        form.host.hostname = "1.2.3.4"
        form.host.jumpHost = "ssh -i .ssh/inner-key.pem 192.0.2.44"
        XCTAssertEqual(form.validationError, .invalidJumpHost)
        form.host.jumpHost = "ubuntu@1.2.3.4"
        XCTAssertNil(form.validationError)
    }

    func testCannotJumpThroughSelf() {
        var form = HostForm(host: SSHHost())
        form.host.hostname = "x"
        form.host.jumpHostID = form.host.id
        XCTAssertEqual(form.validationError, .jumpToSelf)
    }

    // MARK: 명령 생성

    func testSavedJumpHostBecomesProxyCommandWithItsKey() {
        let jump = bastion()
        let target = internalHost(via: jump)
        let args = SSHCommand.arguments(for: target) { $0 == jump.id ? jump : nil }

        let proxyIndex = args.firstIndex(of: "-o").flatMap { _ in args.firstIndex { $0.hasPrefix("ProxyCommand=") } }
        let proxy = try? XCTUnwrap(proxyIndex.map { args[$0] })
        XCTAssertEqual(proxy, "ProxyCommand=ssh -i '/Users/me/keys/cloud key.pem' -o IdentitiesOnly=yes -W %h:%p ubuntu@203.0.113.10")
        XCTAssertEqual(args.last, "ubuntu@192.0.2.44")
        XCTAssertFalse(args.contains("-J"))
    }

    func testNestedJumpHosts() {
        var outer = SSHHost(); outer.hostname = "outer.example.com"
        var middle = SSHHost(); middle.hostname = "10.0.0.1"; middle.jumpHostID = outer.id
        var target = SSHHost(); target.hostname = "10.0.0.2"; target.jumpHostID = middle.id
        let all = [outer, middle, target]
        let args = SSHCommand.arguments(for: target) { id in all.first { $0.id == id } }
        let proxy = args.first { $0.hasPrefix("ProxyCommand=") } ?? ""
        // 안쪽 경유 호스트도 자기 경유를 ProxyCommand 로 가진다 (따옴표로 감싸진 한 인자)
        XCTAssertTrue(proxy.contains("ProxyCommand=ssh -o 'ProxyCommand=ssh -W %h:%p outer.example.com' -W %h:%p 10.0.0.1"), proxy)
    }

    func testMissingJumpHostFallsBackToText() {
        var target = SSHHost()
        target.hostname = "x"
        target.jumpHostID = UUID()
        target.jumpHost = "bastion"
        XCTAssertEqual(SSHCommand.arguments(for: target) { _ in nil }, ["-J", "bastion", "x"])
    }

    func testRemoteCommandOnlyForTerminal() {
        var host = SSHHost()
        host.hostname = "203.0.113.10"
        host.user = "ubuntu"
        host.remoteCommand = "ssh -i .ssh/inner-key.pem 192.0.2.44"
        let launch = SSHCommand.launch(for: host) { _ in nil }

        XCTAssertEqual(launch.displayCommand, "ssh -t ubuntu@203.0.113.10 'ssh -i .ssh/inner-key.pem 192.0.2.44'")
        XCTAssertTrue(launch.commandLine.contains("ControlMaster=auto"))
        XCTAssertTrue(launch.commandLine.hasSuffix("-t ubuntu@203.0.113.10 'ssh -i .ssh/inner-key.pem 192.0.2.44'"))
        XCTAssertFalse(SFTPConnection.arguments(for: launch).contains { $0.contains("inner-key") }, "SFTP 에는 원격 명령을 넣지 않는다")
    }

    /// 실제 ssh 가 생성한 인자를 받아들이고 해석하는지 (-G: 접속하지 않고 설정만 출력)
    func testRealSSHParsesGeneratedArguments() throws {
        let jump = bastion()
        let target = internalHost(via: jump)
        let args = SSHCommand.arguments(for: target) { $0 == jump.id ? jump : nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let config = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0, config)
        XCTAssertTrue(config.contains("hostname 192.0.2.44"), config)
        XCTAssertTrue(config.contains("user ubuntu"), config)
        XCTAssertTrue(config.contains("proxycommand ssh -i '/Users/me/keys/cloud key.pem' -o IdentitiesOnly=yes -W %h:%p ubuntu@203.0.113.10"), config)
    }

    // MARK: 저장·내보내기

    func testNewFieldsArePersistedAndExported() throws {
        let store = HostStore(database: try AppDatabase.inMemory())
        let jump = bastion()
        var target = internalHost(via: jump)
        target.remoteCommand = "htop"
        try store.save(jump)
        try store.save(target)

        let saved = try XCTUnwrap(store.host(target.id))
        XCTAssertEqual(saved.jumpHostID, jump.id)
        XCTAssertEqual(saved.remoteCommand, "htop")

        let decoded = try HostTransfer.decode(HostTransfer.export([jump, target]))
        XCTAssertEqual(decoded[1].jumpHostID, jump.id)
        XCTAssertEqual(decoded[1].remoteCommand, "htop")
    }
}
