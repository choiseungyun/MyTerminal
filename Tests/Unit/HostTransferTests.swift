import XCTest
@testable import MyTerminal

final class HostTransferTests: XCTestCase {
    private func sample() -> [SSHHost] {
        var a = SSHHost()
        a.name = "웹"
        a.hostname = "web.example.com"
        a.user = "deploy"
        a.port = 2222
        a.group = "운영"
        a.tags = ["web"]
        a.authMethod = .password
        a.lastConnectedAt = Date(timeIntervalSince1970: 1_800_000_000)
        a.notes = "메모"

        var b = SSHHost()
        b.hostname = "prod-db"
        b.sshConfigAlias = "prod-db"
        return [a, b]
    }

    func testRoundTrip() throws {
        let hosts = sample()
        let decoded = try HostTransfer.decode(HostTransfer.export(hosts))

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, hosts[0].id)
        XCTAssertEqual(decoded[0].name, "웹")
        XCTAssertEqual(decoded[0].port, 2222)
        XCTAssertEqual(decoded[0].group, "운영")
        XCTAssertEqual(decoded[0].tags, ["web"])
        XCTAssertEqual(decoded[0].authMethod, .password)
        XCTAssertEqual(decoded[0].notes, "메모")
        XCTAssertEqual(decoded[1].sshConfigAlias, "prod-db")
    }

    func testExportNeverContainsPasswordOrPersonalHistory() throws {
        let hosts = sample()
        Keychain.savePassword("export-secret-123", hostID: hosts[0].id)
        defer { Keychain.deletePassword(hostID: hosts[0].id) }

        let json = String(decoding: try HostTransfer.export(hosts), as: UTF8.self)
        XCTAssertFalse(json.contains("export-secret-123"))
        XCTAssertFalse(json.contains("lastConnectedAt"))
        XCTAssertFalse(json.contains("createdAt"))
        XCTAssertTrue(json.contains("\"format\" : \"myterminal.hosts\""))
    }

    func testDecodeRejectsOtherFiles() {
        XCTAssertThrowsError(try HostTransfer.decode(Data("not json".utf8))) {
            XCTAssertEqual($0 as? HostTransfer.ImportError, .invalidJSON)
        }
        XCTAssertThrowsError(try HostTransfer.decode(Data(#"{"name":"x"}"#.utf8))) {
            XCTAssertEqual($0 as? HostTransfer.ImportError, .notHostFile)
        }
        let future = #"{"format":"myterminal.hosts","version":99,"exportedAt":"2026-01-01T00:00:00Z","hosts":[]}"#
        XCTAssertThrowsError(try HostTransfer.decode(Data(future.utf8))) {
            XCTAssertEqual($0 as? HostTransfer.ImportError, .unsupportedVersion(99))
        }
        let empty = #"{"format":"myterminal.hosts","version":1,"exportedAt":"2026-01-01T00:00:00Z","hosts":[{"hostname":"  "}]}"#
        XCTAssertThrowsError(try HostTransfer.decode(Data(empty.utf8))) {
            XCTAssertEqual($0 as? HostTransfer.ImportError, .empty)
        }
    }

    func testDecodeToleratesMissingOptionalFields() throws {
        let minimal = #"{"format":"myterminal.hosts","version":1,"exportedAt":"2026-01-01T00:00:00Z","hosts":[{"hostname":"a","authMethod":"unknown","port":99999}]}"#
        let host = try XCTUnwrap(HostTransfer.decode(Data(minimal.utf8)).first)
        XCTAssertEqual(host.hostname, "a")
        XCTAssertEqual(host.authMethod, .auto)
        XCTAssertNil(host.port, "범위를 벗어난 포트는 버린다")
        XCTAssertEqual(host.tags, [])
    }

    func testPlanMatchesByIdThenByTarget() {
        var existing1 = SSHHost(); existing1.hostname = "a"; existing1.user = "u"
        var existing2 = SSHHost(); existing2.hostname = "b"
        var sameID = existing1; sameID.name = "이름 바뀜"
        var sameTarget = SSHHost(); sameTarget.hostname = "B"           // 대소문자 무시
        var different = SSHHost(); different.hostname = "a"; different.user = "other"

        let items = HostTransfer.plan(incoming: [sameID, sameTarget, different], existing: [existing1, existing2])
        XCTAssertEqual(items[0].existing?.id, existing1.id)
        XCTAssertEqual(items[1].existing?.id, existing2.id)
        XCTAssertNil(items[2].existing)
    }

    func testResolvePolicies() {
        var existing = SSHHost(); existing.hostname = "a"
        existing.lastConnectedAt = Date(timeIntervalSince1970: 100)
        var incoming = SSHHost(); incoming.hostname = "a"; incoming.name = "새 이름"
        var brandNew = SSHHost(); brandNew.hostname = "z"
        let items = HostTransfer.plan(incoming: [incoming, brandNew], existing: [existing])

        let skip = HostTransfer.resolve(items, policy: .skip)
        XCTAssertEqual(skip.insert.map(\.hostname), ["z"])
        XCTAssertTrue(skip.update.isEmpty)

        let overwrite = HostTransfer.resolve(items, policy: .overwrite)
        XCTAssertEqual(overwrite.update.first?.id, existing.id, "기존 id 유지 (비밀번호 연결)")
        XCTAssertEqual(overwrite.update.first?.name, "새 이름")
        XCTAssertEqual(overwrite.update.first?.lastConnectedAt, existing.lastConnectedAt)

        let both = HostTransfer.resolve(items, policy: .keepBoth)
        XCTAssertEqual(both.insert.count, 2)
        XCTAssertNotEqual(both.insert.first?.id, existing.id)
        XCTAssertEqual(both.insert.first?.name, "새 이름 (가져옴)")
    }

    func testApplyToStore() throws {
        let store = HostStore(database: try AppDatabase.inMemory())
        var existing = SSHHost(); existing.hostname = "a"; existing.name = "옛 이름"
        try store.save(existing)

        var incoming = SSHHost(); incoming.hostname = "a"; incoming.name = "새 이름"
        var other = SSHHost(); other.hostname = "b"
        let result = HostTransfer.resolve(
            HostTransfer.plan(incoming: [incoming, other], existing: store.hosts), policy: .overwrite)
        try store.apply(insert: result.insert, update: result.update)

        XCTAssertEqual(store.hosts.count, 2)
        XCTAssertEqual(store.host(existing.id)?.name, "새 이름")
    }
}
