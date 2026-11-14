import AppKit
import XCTest
@testable import MyTerminal

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testClosingLastWindowQuits() {
        XCTAssertTrue(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }

    func testNoConfirmationWithoutTerminals() {
        XCTAssertNil(AppDelegate.confirmationMessage(for: WorkspaceStore.forTesting()))
    }

    func testConfirmationCountsTerminalsAndSSH() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        XCTAssertEqual(AppDelegate.confirmationMessage(for: store),
                       "터미널 1개 가 열려 있습니다. 종료하면 모두 닫히고 접속이 끊어집니다.")

        var host = SSHHost()
        host.hostname = "no-such-host.invalid"
        store.connect(host)
        store.splitCurrentPane(.horizontal, choice: .same)
        XCTAssertEqual(AppDelegate.confirmationMessage(for: store),
                       "터미널 3개 (SSH 접속 2개) 가 열려 있습니다. 종료하면 모두 닫히고 접속이 끊어집니다.")

        store.openSFTP(host)
        XCTAssertTrue(AppDelegate.confirmationMessage(for: store)?.contains("SFTP 접속 1개") == true)
    }
}

@MainActor
final class MainWindowCloseTests: XCTestCase {
    /// 닫기 버튼이 창을 바로 닫지 않고 종료 절차(확인 시트)로 가는지
    func testCloseButtonIsRoutedToTerminationFlow() throws {
        let delegate = AppDelegate()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        delegate.attach(to: window)

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertTrue(close.target === delegate)
        XCTAssertEqual(close.action, #selector(AppDelegate.closeButtonClicked(_:)))
        XCTAssertTrue(delegate.mainWindow === window)
        XCTAssertFalse(window.isMovable, "탭을 끌 때 창이 같이 움직이지 않도록 자동 이동은 끈다")
    }

    func testTerminatesImmediatelyWithoutTerminals() {
        let delegate = AppDelegate()
        delegate.terminationWatchdogEnabled = false   // 실제로 끝내지 않는다 (켜 두면 몇 초 뒤 테스트가 종료됨)
        let store = WorkspaceStore.forTesting()
        delegate.store = store
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }
}

final class TerminationFlagTests: XCTestCase {
    /// 종료 정리는 메인 스레드·감시 스레드 중 먼저 온 쪽만 한다
    func testBeginsOnlyOnce() {
        let flag = TerminationFlag()
        var wins = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            if flag.begin() { lock.withLock { wins += 1 } }
        }
        XCTAssertEqual(wins, 1)
        XCTAssertFalse(flag.begin())
    }

    func testExitHistoryWriteEndsOpenRecords() throws {
        let history = HistoryStore(database: try AppDatabase.inMemory())
        let id = history.start(SSHCommand.launch(for: QuickConnectTarget("u@h")!), kind: .ssh)
        history.endAllOpenForExit()
        history.reload()
        XCTAssertNotNil(history.records.first { $0.id == id }?.endedAt)
    }
}

final class DragPromiseReleaseTests: XCTestCase {
    /// 회귀: 서버 파일을 끈 뒤 × 로 종료하면 멈춤 (macOS 가 종료 때 남은 끌어 놓기 약속을 메인 스레드에서 채우라고 요청).
    /// 종료 전에 칠판을 비워 약속을 푼다.
    final class Promise: NSObject, NSPasteboardItemDataProvider {
        var requested = false
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            requested = true
        }
    }

    func testReleasesPendingPromises() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kr.weare.myterminal.test-drag-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let promise = Promise()
        let item = NSPasteboardItem()
        item.setDataProvider(promise, forTypes: [NSPasteboard.PasteboardType("public.data")])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)

        AppDelegate.releaseDragPromises(pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count ?? 0, 0)
        XCTAssertFalse(promise.requested, "비울 때 약속을 채우라고 요청하지 않는다")
    }
}
