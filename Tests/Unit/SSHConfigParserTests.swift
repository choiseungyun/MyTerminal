import XCTest
@testable import MyTerminal

final class SSHConfigParserTests: XCTestCase {
    func testBasicHostBlocks() {
        let entries = SSHConfigParser.parse("""
        # 회사 서버
        Host web-01
            HostName 10.0.0.5
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_work

        Host db
          hostname=db.internal
          user = admin
          ProxyJump bastion
        """)

        XCTAssertEqual(entries.map(\.alias), ["web-01", "db"])
        XCTAssertEqual(entries[0].hostname, "10.0.0.5")
        XCTAssertEqual(entries[0].user, "deploy")
        XCTAssertEqual(entries[0].port, 2222)
        XCTAssertEqual(entries[0].identityFile, "~/.ssh/id_work")
        XCTAssertEqual(entries[1].hostname, "db.internal")
        XCTAssertEqual(entries[1].user, "admin")
        XCTAssertEqual(entries[1].proxyJump, "bastion")
    }

    func testWildcardsAreSkippedAndMultipleAliasesShareOptions() {
        let entries = SSHConfigParser.parse("""
        Host *
            User everyone
        Host app1 app2 *.internal !bad
            User app
        """)
        XCTAssertEqual(entries.map(\.alias), ["app1", "app2"])
        XCTAssertEqual(entries.map(\.user), ["app", "app"])
    }

    func testFirstValueWins() {
        let entries = SSHConfigParser.parse("""
        Host x
            User first
            User second
        """)
        XCTAssertEqual(entries.first?.user, "first")
    }

    func testMatchBlockIsIgnored() {
        let entries = SSHConfigParser.parse("""
        Host a
            User ua
        Match host b
            User should-not-apply
        Host c
        """)
        XCTAssertEqual(entries.map(\.alias), ["a", "c"])
        XCTAssertEqual(entries.first?.user, "ua")
        XCTAssertNil(entries.last?.user)
    }

    func testQuotedValues() {
        let entries = SSHConfigParser.parse("""
        Host "my server"
            IdentityFile "/Users/me/My Keys/id"
        """)
        XCTAssertEqual(entries.first?.alias, "my server")
        XCTAssertEqual(entries.first?.identityFile, "/Users/me/My Keys/id")
    }

    func testIncludeWithWildcard() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sshcfg-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("config.d")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "Host inc-a\n  User a\n".write(to: sub.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)
        try "Host inc-b\n".write(to: sub.appendingPathComponent("b.conf"), atomically: true, encoding: .utf8)

        let entries = SSHConfigParser.parse("""
        Include \(sub.path)/*.conf
        Host main
        """)
        XCTAssertEqual(entries.map(\.alias), ["inc-a", "inc-b", "main"])
        XCTAssertEqual(entries.first?.user, "a")
    }

    func testIncludeLoopDoesNotHang() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sshcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("loop")
        try "Include \(file.path)\nHost looped\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(SSHConfigParser.parseFile(at: file).map(\.alias), ["looped"])
    }

    func testMakeHostUsesAliasForConnection() {
        let entry = SSHConfigEntry(alias: "prod", hostname: "10.1.1.1", user: "ops")
        let host = entry.makeHost(group: "SSH Config")
        XCTAssertEqual(host.sshConfigAlias, "prod")
        XCTAssertEqual(host.hostname, "10.1.1.1")
        XCTAssertEqual(host.group, "SSH Config")
        XCTAssertEqual(SSHCommand.arguments(for: host), ["prod"])
    }

    func testMissingFileReturnsEmpty() {
        XCTAssertTrue(SSHConfigParser.parseFile(at: URL(fileURLWithPath: "/nonexistent/config")).isEmpty)
    }
}
