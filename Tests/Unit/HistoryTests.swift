import XCTest
@testable import MyTerminal

extension WorkspaceStore {
    /// 테스트용: 접속 이력을 메모리 데이터베이스에 기록한다 (사용자의 실제 이력을 건드리지 않음)
    static func forTesting() -> WorkspaceStore {
        WorkspaceStore(history: HistoryStore(database: try! AppDatabase.inMemory()))
    }
}

final class HistoryStoreTests: XCTestCase {
    private var history: HistoryStore!

    override func setUpWithError() throws {
        history = HistoryStore(database: try AppDatabase.inMemory())
    }

    private func launch(_ args: [String], hostID: UUID? = nil) -> SSHLaunch {
        SSHLaunch(title: "web", user: "deploy", arguments: args, hostID: hostID)
    }

    func testStartEndAndOrder() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = history.start(launch(["deploy@a"]), kind: .ssh, at: t0)
        let b = history.start(launch(["deploy@b"]), kind: .sftp, at: t0.addingTimeInterval(60))
        history.end(a, at: t0.addingTimeInterval(120))

        XCTAssertEqual(history.records.map(\.id), [b, a], "최근 접속이 먼저")
        XCTAssertEqual(history.records[1].endedAt, t0.addingTimeInterval(120))
        XCTAssertNil(history.records[0].endedAt)
        XCTAssertEqual(history.records[0].kind, .sftp)
        XCTAssertEqual(history.records[1].localUser, NSUserName())
        XCTAssertFalse(history.records[1].localMachine.isEmpty)

        // 이미 끝난 기록은 다시 끝내지 않는다
        history.end(a, at: t0.addingTimeInterval(999))
        XCTAssertEqual(history.records[1].endedAt, t0.addingTimeInterval(120))
    }

    func testEndAllOpen() {
        _ = history.start(launch(["x"]), kind: .ssh)
        _ = history.start(launch(["y"]), kind: .ssh)
        history.endAllOpen()
        XCTAssertTrue(history.records.allSatisfy { $0.endedAt != nil })
    }

    func testLinkDeleteClear() {
        let a = history.start(launch(["deploy@a"]), kind: .ssh)
        _ = history.start(launch(["deploy@a"]), kind: .ssh)
        _ = history.start(launch(["other"]), kind: .ssh)
        let hostID = UUID()
        history.link(arguments: ["deploy@a"], to: hostID)
        XCTAssertEqual(history.records.filter { $0.hostID == hostID }.count, 2)

        history.delete([a])
        XCTAssertEqual(history.records.count, 2)
        history.clear()
        XCTAssertTrue(history.records.isEmpty)
    }

    func testQuickTargetRoundTrip() {
        let record = ConnectionRecord(
            kind: .ssh, title: "x", user: "admin", arguments: ["-p", "2222", "admin@10.0.0.5"],
            startedAt: Date(), localUser: "me", localMachine: "mac")
        let host = SSHHost(quickConnect: record.quickTarget!)
        XCTAssertEqual(host.hostname, "10.0.0.5")
        XCTAssertEqual(host.user, "admin")
        XCTAssertEqual(host.port, 2222)
    }

    func testTimeRangeFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 13, minute: 42))!
        var record = ConnectionRecord(kind: .ssh, title: "x", arguments: [], startedAt: start, localUser: "", localMachine: "")

        XCTAssertEqual(HistoryFormat.timeRange(record, isOpen: true, calendar: calendar), "13:42 - 접속 중")
        XCTAssertEqual(HistoryFormat.timeRange(record, isOpen: false, calendar: calendar), "13:42 - 종료 기록 없음")
        record.endedAt = calendar.date(byAdding: .minute, value: 9, to: start)
        XCTAssertEqual(HistoryFormat.timeRange(record, isOpen: false, calendar: calendar), "13:42 - 13:51")
        record.endedAt = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 9, minute: 59))
        XCTAssertEqual(HistoryFormat.timeRange(record, isOpen: false, calendar: calendar), "13:42 - 09:59 (+2일)")
        XCTAssertEqual(HistoryFormat.day(start), "2026년 3월 13일")
    }
}

/// 실제 탭·화면 열고 닫기와 이력 기록
@MainActor
final class WorkspaceHistoryTests: XCTestCase {
    private func host() -> SSHHost {
        var h = SSHHost()
        h.hostname = "no-such-host.invalid"
        h.user = "deploy"
        return h
    }

    func testTerminalConnectionsAreRecordedAndEnded() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        XCTAssertTrue(store.history.records.isEmpty, "로컬 터미널은 기록하지 않는다")

        let h = host()
        store.connect(h)
        XCTAssertEqual(store.history.records.count, 1)
        XCTAssertEqual(store.history.records[0].hostID, h.id)
        XCTAssertEqual(store.history.records[0].kind, .ssh)
        XCTAssertTrue(store.isOpen(store.history.records[0]))

        // 분할하면 같은 서버에 한 번 더 접속 → 기록 하나 더
        store.splitCurrentPane(.horizontal, choice: .same)
        XCTAssertEqual(store.history.records.count, 2)

        // 화면 하나 닫기 → 그 기록만 끝남
        store.closeCurrentPane()
        XCTAssertEqual(store.history.records.filter { $0.endedAt != nil }.count, 1)

        // 탭 닫기 → 나머지도 끝남
        store.closeTab(store.currentTab!.id)
        XCTAssertTrue(store.history.records.allSatisfy { $0.endedAt != nil })
        XCTAssertFalse(store.history.records.contains { store.isOpen($0) })
    }

    func testSFTPConnectionsAreRecorded() {
        let store = WorkspaceStore.forTesting()
        store.openSFTP(host())
        store.openSFTP(QuickConnectTarget("ops@other.invalid")!)
        XCTAssertEqual(store.history.records.count, 2)
        XCTAssertEqual(store.history.records.filter { $0.endedAt != nil }.count, 1, "호스트를 바꾸면 이전 접속은 끝남")
        XCTAssertTrue(store.history.records.allSatisfy { $0.kind == .sftp })

        store.closeSFTPRemote()
        XCTAssertTrue(store.history.records.allSatisfy { $0.endedAt != nil })
    }
}

/// SSH 화면이 끝났을 때: 정상 종료면 닫고, 오류면 남긴다.
@MainActor
final class SSHExitTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    func testWrapperRecordsRealExitCode() {
        let line = ExitStatus.wrap("ssh -p 2222 'deploy@web 1'")
        XCTAssertTrue(line.hasPrefix("/bin/sh -c '"))
        XCTAssertTrue(line.hasSuffix(" myterminal ssh -p 2222 'deploy@web 1'"))
    }

    /// `ssh -V` 는 서버 없이 0 으로 끝난다 → 정상 로그아웃과 같은 경로
    func testNormalExitClosesTab() async {
        let store = WorkspaceStore.forTesting()
        store.connect(QuickConnectTarget("-V")!)
        XCTAssertEqual(store.tabs.count, 1)
        await waitUntil { store.tabs.isEmpty }
        XCTAssertTrue(store.tabs.isEmpty, "종료 코드 0 이면 탭이 닫힌다")
        XCTAssertTrue(store.history.records.allSatisfy { $0.endedAt != nil }, "이력에 끝 시각")
    }

    /// 접속 실패(255)는 메시지를 볼 수 있게 남긴다
    func testErrorExitKeepsTab() async {
        let store = WorkspaceStore.forTesting()
        store.connect(QuickConnectTarget("-o ConnectTimeout=3 no-such-host.invalid")!)
        let pane = store.tabs.first?.panes.first
        await waitUntil { pane?.exitStatus != nil }
        XCTAssertEqual(pane?.exitStatus, 255)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(store.tabs.count, 1, "오류로 끝나면 탭을 남긴다")
        XCTAssertEqual(pane?.connectionFailure, 255, "AI 접속 실패 진단 버튼을 보인다")
        XCTAssertTrue(store.canDiagnoseConnection)
    }
}
