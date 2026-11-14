import XCTest
@testable import MyTerminal

final class HostStoreTests: XCTestCase {
    private var store: HostStore!

    override func setUpWithError() throws {
        store = HostStore(database: try AppDatabase.inMemory())
    }

    func testSaveAndFetch() throws {
        var host = SSHHost()
        host.name = "운영 웹"
        host.hostname = "10.0.0.5"
        host.user = "deploy"
        host.port = 2222
        host.group = "운영"
        host.tags = ["web", "prod"]
        try store.save(host)

        XCTAssertEqual(store.hosts.count, 1)
        let saved = try XCTUnwrap(store.hosts.first)
        XCTAssertEqual(saved.displayName, "운영 웹")
        XCTAssertEqual(saved.port, 2222)
        XCTAssertEqual(saved.group, "운영")
        XCTAssertEqual(saved.tags, ["web", "prod"])
        XCTAssertEqual(store.groups, ["운영"])
    }

    func testUpdateKeepsSingleRow() throws {
        var host = SSHHost()
        host.hostname = "a.example.com"
        try store.save(host)
        host.name = "A 서버"
        try store.save(host)

        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(store.hosts.first?.displayName, "A 서버")
    }

    func testDelete() throws {
        var host = SSHHost()
        host.hostname = "b.example.com"
        try store.save(host)
        try store.delete(host.id)
        XCTAssertTrue(store.hosts.isEmpty)
    }

    func testMarkConnected() throws {
        var host = SSHHost()
        host.hostname = "c.example.com"
        try store.save(host)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        store.markConnected(host.id, at: date)
        XCTAssertEqual(store.hosts.first?.lastConnectedAt, date)
    }

    func testSearchMatchesNameHostUserGroupAndTags() {
        var host = SSHHost()
        host.name = "결제 API"
        host.hostname = "pay.internal"
        host.user = "ops"
        host.group = "운영"
        host.tags = ["kafka"]

        for query in ["결제", "pay.int", "OPS", "운영", "kaf", ""] {
            XCTAssertTrue(host.matches(query), query)
        }
        XCTAssertFalse(host.matches("staging"))
    }

    func testDisplayNameFallsBackToAliasThenHostname() {
        var host = SSHHost()
        host.hostname = "1.2.3.4"
        XCTAssertEqual(host.displayName, "1.2.3.4")
        host.sshConfigAlias = "bastion"
        XCTAssertEqual(host.displayName, "bastion")
        host.name = "  "
        XCTAssertEqual(host.displayName, "bastion")
    }
}

final class SSHCommandTests: XCTestCase {
    func testBasicHost() {
        var host = SSHHost()
        host.hostname = "web-01"
        host.user = "deploy"
        XCTAssertEqual(SSHCommand.arguments(for: host), ["deploy@web-01"])
        XCTAssertEqual(SSHCommand.launch(for: host).displayCommand, "ssh deploy@web-01")
        XCTAssertTrue(SSHCommand.launch(for: host).commandLine.hasSuffix(" deploy@web-01"))
    }

    func testPortKeyAndJump() {
        var host = SSHHost()
        host.hostname = "db.internal"
        host.user = "admin"
        host.port = 2222
        host.identityFile = "/Users/me/.ssh/id_ed25519"
        host.jumpHost = "bastion"
        XCTAssertEqual(SSHCommand.arguments(for: host), [
            "-p", "2222",
            "-i", "/Users/me/.ssh/id_ed25519", "-o", "IdentitiesOnly=yes",
            "-J", "bastion",
            "admin@db.internal",
        ])
    }

    func testDefaultPortIsOmitted() {
        var host = SSHHost()
        host.hostname = "x"
        host.port = 22
        XCTAssertEqual(SSHCommand.arguments(for: host), ["x"])
    }

    func testSSHConfigHostUsesAliasOnly() {
        var host = SSHHost()
        host.hostname = "10.0.0.9"
        host.user = "ignored"
        host.sshConfigAlias = "prod-db"
        XCTAssertEqual(SSHCommand.arguments(for: host), ["prod-db"])
    }

    func testShellQuoting() {
        XCTAssertEqual(SSHCommand.shellQuote("deploy@web-01"), "deploy@web-01")
        XCTAssertEqual(SSHCommand.shellQuote("/Users/me/My Keys/id"), "'/Users/me/My Keys/id'")
        XCTAssertEqual(SSHCommand.shellQuote("a;rm -rf ~"), "'a;rm -rf ~'")
        XCTAssertEqual(SSHCommand.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(SSHCommand.shellQuote(""), "''")
    }

    func testCommandLineReusesConnection() {
        var host = SSHHost()
        host.hostname = "x"
        let line = SSHCommand.launch(for: host).commandLine
        XCTAssertTrue(line.hasPrefix("ssh -o ControlMaster=auto -o ControlPath=/tmp/myterm-"), line)
        XCTAssertTrue(line.contains("%C"))
        XCTAssertTrue(SSHMultiplex.prepare())

        var info = Darwin.stat()
        XCTAssertEqual(lstat(SSHMultiplex.directory, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(info.st_uid, getuid())
    }

    func testQuickConnectArguments() {
        let launch = SSHCommand.launch(for: QuickConnectTarget("ssh -p 2222  admin@10.0.0.5")!)
        XCTAssertEqual(launch.arguments, ["-p", "2222", "admin@10.0.0.5"])
        XCTAssertEqual(launch.hostNames, ["10.0.0.5"])
    }

    func testPasswordHostRequestsSavedPassword() {
        var host = SSHHost()
        host.hostname = "x"
        host.authMethod = .password
        XCTAssertTrue(SSHCommand.launch(for: host).usesSavedPassword)
        XCTAssertEqual(SSHCommand.launch(for: host).hostID, host.id)
    }
}
