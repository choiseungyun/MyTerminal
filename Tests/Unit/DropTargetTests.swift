import AppKit
import SwiftUI
import XCTest
@testable import MyTerminal

/// 회귀: SwiftUI List 의 내부 AppKit 표가 놓기를 가로채 SFTP 끌어다 놓기가 동작하지 않았다.
/// AppKit 은 끄는 위치를 덮는 요소 중 놓기를 등록한 가장 깊은(앞쪽) 요소를 놓기 대상으로 삼는다.
/// (클릭용 hitTest 와 다르다: SwiftUI 의 놓기 요소는 클릭을 통과시키지만 놓기는 받는다)
/// 목록 위 어느 점에서든 그 요소가 파일을 받아야 하고, 목록 안에 AppKit 표가 있으면 안 된다.
@MainActor
final class DropTargetTests: XCTestCase {
    private func show(_ view: some View) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        settle(window)
        return window
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// 점을 덮는 놓기 등록 요소 중 가장 깊은(앞쪽) 것의 형식
    private func firstDropTypes(in window: NSWindow, at point: NSPoint) -> [String]? {
        func search(_ view: NSView) -> [String]? {
            guard !view.isHidden, view.convert(view.bounds, to: nil).contains(point) else { return nil }
            for sub in view.subviews.reversed() {   // 앞쪽(나중에 추가된) 요소부터
                if let found = search(sub) { return found }
            }
            return view.registeredDraggedTypes.isEmpty ? nil : view.registeredDraggedTypes.map(\.rawValue)
        }
        return window.contentView.flatMap(search)
    }

    private func containsTable(_ view: NSView) -> Bool {
        view is NSTableView || view.subviews.contains(where: containsTable)
    }

    private func assertAcceptsFiles(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(containsTable(window.contentView!), "목록에 AppKit 표가 있으면 놓기를 가로챌 수 있음", file: file, line: line)
        // 목록 영역의 여러 점 (행 위, 빈 곳)
        for y in [40.0, 150.0, 300.0, 450.0] {   // 창 아래쪽이 0, 목록 영역 안
            let types = firstDropTypes(in: window, at: NSPoint(x: 260, y: y)) ?? []
            let acceptsFiles = types.contains { $0 == "public.file-url" || $0 == "public.item" || $0 == "public.data" || $0 == "public.url" }
            XCTAssertTrue(acceptsFiles, "y=\(y): 처음 만나는 놓기 대상이 파일을 받지 않음: \(types)", file: file, line: line)
        }
    }

    func testLocalPaneAcceptsFileDrops() {
        let window = show(LocalBrowserPanel(browser: LocalBrowser(directory: URL(fileURLWithPath: "/usr")))
            .environmentObject(WorkspaceStore.forTesting()))
        defer { window.orderOut(nil) }
        assertAcceptsFiles(window)
    }

    func testRemotePaneAcceptsFileDrops() async throws {
        let browser = RemoteBrowser(launch: SSHLaunch(title: "t", arguments: ["t"])) { _ in
            let client = try await SFTPClient(transport: ProcessTransport(executable: "/usr/libexec/sftp-server", arguments: []))
            return (client, client.close)
        }
        await browser.connectIfNeeded()
        await browser.open("/usr")
        XCTAssertFalse(browser.entries.isEmpty)

        let window = show(FileBrowserPanel(browser: browser, title: "t"))
        defer { window.orderOut(nil); browser.disconnect() }
        assertAcceptsFiles(window)
    }
}

/// 회귀: SFTP 탭에서 서버에 들어가면 오른쪽 칸이 줄어들었다 (HSplitView 가 내용 폭으로 다시 나눔).
@MainActor
final class SFTPSplitTests: XCTestCase {
    func testPaneWidths() {
        let half = SFTPView.paneWidths(total: 1208, ratio: 0.5)
        XCTAssertEqual(half.left, 600)
        XCTAssertEqual(half.right, 600)
        XCTAssertEqual(SFTPView.paneWidths(total: 1208, ratio: 0.05).left, SFTPView.minPaneWidth, "최소 폭 보장")
        XCTAssertEqual(SFTPView.paneWidths(total: 1208, ratio: 0.95).right, SFTPView.minPaneWidth)
    }

    func testRightPaneKeepsWidthAfterEnteringServer() async throws {
        let key = "sftp.splitRatio"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(0.5, forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }

        let store = WorkspaceStore.forTesting()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1208, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SFTPView(local: LocalBrowser(directory: URL(fileURLWithPath: "/usr")))
            .environmentObject(store)
            .environmentObject(HostStore(database: try AppDatabase.inMemory())))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        func settle() {
            for _ in 0..<15 { window.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        }
        /// 칸마다 하나씩 있는 파일 목록 놓기 영역의 (x, 폭)
        func dropAreas() -> [(x: CGFloat, width: CGFloat)] {
            var result: [(CGFloat, CGFloat)] = []
            func walk(_ v: NSView) {
                if String(describing: type(of: v)).contains("DraggingDestination") {
                    let f = v.convert(v.bounds, to: nil)
                    result.append((f.minX, f.width))
                }
                v.subviews.forEach(walk)
            }
            walk(window.contentView!)
            // SwiftUI 가 같은 자리에 놓기 요소를 두 겹 만들 수 있어 위치·폭이 같은 것은 하나로 본다
            var unique: [(CGFloat, CGFloat)] = []
            for r in result where !unique.contains(where: { abs($0.0 - r.0) < 1 && abs($0.1 - r.1) < 1 }) { unique.append(r) }
            return unique.sorted { $0.0 < $1.0 }
        }

        settle()
        XCTAssertEqual(dropAreas().first?.width ?? 0, 600, accuracy: 2, "호스트 고르기 상태의 왼쪽 칸")

        // 서버에 들어감 (로컬 sftp-server 로 대신)
        let remote = RemoteBrowser(launch: SSHLaunch(title: "t", arguments: ["t"])) { _ in
            let client = try await SFTPClient(transport: ProcessTransport(executable: "/usr/libexec/sftp-server", arguments: []))
            return (client, client.close)
        }
        store.sftpRemote = remote
        await remote.connectIfNeeded()
        await remote.open("/usr")
        settle()

        let areas = dropAreas()
        XCTAssertEqual(areas.count, 2, "왼쪽·오른쪽 목록")
        XCTAssertEqual(areas.first?.width ?? 0, 600, accuracy: 2, "왼쪽 칸 폭 유지")
        XCTAssertEqual(areas.last?.width ?? 0, 600, accuracy: 2, "오른쪽 칸이 줄어들지 않음")
        remote.disconnect()
    }
}
