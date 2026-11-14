import AppKit
import SwiftUI
import XCTest
@testable import MyTerminal

/// 실제 창에 TerminalTabView 를 띄워 분할·닫기 후 터미널 화면(NSView)이 제자리에 붙어 있는지 검사한다.
@MainActor
final class PaneLayoutTests: XCTestCase {
    private var window: NSWindow!

    /// 테스트 창 크기. CI 러너 화면(1024×768)에서도 줄어들지 않도록 작게 잡고, 기대값은 이 크기의 비율로 쓴다.
    private static let W: CGFloat = 960
    private static let H: CGFloat = 560
    private var W: CGFloat { Self.W }
    private var H: CGFloat { Self.H }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func show(_ tab: TerminalTab, store: WorkspaceStore = .forTesting()) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.W, height: Self.H),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TerminalTabView(tab: tab).environmentObject(store))
        window.orderFront(nil)
        settle()
    }

    /// SwiftUI 갱신과 레이아웃이 끝나도록 런루프를 돌린다.
    private func settle() {
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// 화면이 이 창에 붙어 있고, 창 안에서 차지하는 영역을 돌려준다.
    private func frameInWindow(_ pane: TerminalPane, file: StaticString = #filePath, line: UInt = #line) -> NSRect {
        XCTAssertTrue(pane.view.window === window, "화면이 창에 붙어 있지 않음", file: file, line: line)
        return pane.view.convert(pane.view.bounds, to: nil)
    }

    /// 왼쪽 | (오른쪽 위 / 오른쪽 아래) 에서 오른쪽 아래를 닫으면 오른쪽 위가 오른쪽 전체를 채운다.
    func testClosingBottomRightPaneLetsTopRightFillRightSide() {
        let a = TerminalPane(target: nil)
        let tab = TerminalTab(pane: a)
        let b = TerminalPane(target: nil)
        tab.root = tab.root.splitting(a.id, with: b, axis: .horizontal)
        let c = TerminalPane(target: nil)
        tab.root = tab.root.splitting(b.id, with: c, axis: .vertical)
        tab.focusedPaneID = c.id
        show(tab)

        let rightTop = frameInWindow(b)
        XCTAssertGreaterThan(rightTop.minX, W * 0.42)

        // WorkspaceStore.closePane 과 같은 순서
        tab.root = tab.root.removing(c.id)!
        tab.focusedPaneID = b.id
        settle()

        let left = frameInWindow(a)
        let right = frameInWindow(b)
        XCTAssertNil(c.view.window, "닫은 화면이 창에 남아 있음")
        XCTAssertEqual(left.minX, 0, accuracy: 1)
        XCTAssertGreaterThan(right.minX, W * 0.42, "오른쪽 화면 위치가 이상함: \(right)")
        XCTAssertGreaterThan(right.height, H * 0.85, "오른쪽 화면이 세로를 다 채우지 못함: \(right)")
        XCTAssertGreaterThan(right.width, W * 0.42, "오른쪽 화면 너비가 이상함: \(right)")
    }

    /// 닫은 뒤 남은 화면이 키 입력 포커스를 받고, 다시 분할·연속 닫기를 해도 화면이 창에 붙어 있다.
    func testFocusAndRepeatedSplitClose() {
        let a = TerminalPane(target: nil)
        let tab = TerminalTab(pane: a)
        let b = TerminalPane(target: nil)
        tab.root = tab.root.splitting(a.id, with: b, axis: .horizontal)
        let c = TerminalPane(target: nil)
        tab.root = tab.root.splitting(b.id, with: c, axis: .vertical)
        tab.focusedPaneID = c.id
        show(tab)

        tab.root = tab.root.removing(c.id)!
        tab.focusedPaneID = b.id
        settle()
        XCTAssertTrue(window.firstResponder === b.view, "닫은 뒤 남은 화면에 포커스가 없음")

        // 다시 위아래로 나눴다가, 이번엔 위(b)를 닫는다.
        let d = TerminalPane(target: nil)
        tab.root = tab.root.splitting(b.id, with: d, axis: .vertical)
        tab.focusedPaneID = d.id
        settle()
        // 창 좌표는 아래가 0 이므로, 아래 화면(d)의 위쪽 끝이 위 화면(b)의 아래쪽 끝 이하
        XCTAssertLessThanOrEqual(frameInWindow(d).maxY, frameInWindow(b).minY + 1)

        tab.root = tab.root.removing(b.id)!
        tab.focusedPaneID = d.id
        settle()
        let right = frameInWindow(d)
        XCTAssertNil(b.view.window)
        XCTAssertGreaterThan(right.height, H * 0.85, "오른쪽 화면이 세로를 다 채우지 못함: \(right)")
        XCTAssertTrue(window.firstResponder === d.view)

        // 마지막으로 왼쪽까지 닫으면 d 하나가 창 전체
        tab.root = tab.root.removing(a.id)!
        settle()
        let full = frameInWindow(d)
        XCTAssertGreaterThan(full.width, W * 0.95, "남은 화면이 창 전체를 채우지 못함: \(full)")
    }

    /// 반대로 왼쪽을 닫으면 오른쪽 분할(위/아래)이 창 전체를 채운다.
    func testClosingLeftPaneLetsRightSplitFillWindow() {
        let a = TerminalPane(target: nil)
        let tab = TerminalTab(pane: a)
        let b = TerminalPane(target: nil)
        tab.root = tab.root.splitting(a.id, with: b, axis: .horizontal)
        let c = TerminalPane(target: nil)
        tab.root = tab.root.splitting(b.id, with: c, axis: .vertical)
        tab.focusedPaneID = a.id
        show(tab)

        tab.root = tab.root.removing(a.id)!
        tab.focusedPaneID = b.id
        settle()

        let top = frameInWindow(b)
        let bottom = frameInWindow(c)
        XCTAssertNil(a.view.window, "닫은 화면이 창에 남아 있음")
        XCTAssertEqual(top.minX, 0, accuracy: 1)
        XCTAssertGreaterThan(top.width, W * 0.95, "위 화면이 가로를 다 채우지 못함: \(top)")
        XCTAssertGreaterThan(bottom.width, W * 0.95, "아래 화면이 가로를 다 채우지 못함: \(bottom)")
    }

    /// 파일 패널은 저장된 폭을 쓰고, 창의 75% 를 넘지 않는다.
    func testFilePanelUsesStoredWidthWithinLimit() {
        let key = "filePanel.width"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let pane = TerminalPane(target: nil)
        let tab = TerminalTab(pane: pane)
        tab.showsFilePanel = true

        UserDefaults.standard.set(400.0, forKey: key)
        show(tab)
        // 창 폭 - 패널 400 - 경계 막대
        let handle = PanelResizeHandle.thickness
        XCTAssertEqual(frameInWindow(pane).width, W - 400 - handle, accuracy: 3)

        UserDefaults.standard.set(5000.0, forKey: key)
        settle()
        XCTAssertEqual(frameInWindow(pane).width, W * 0.25 - handle, accuracy: 3, "창의 75% 까지만")
    }

    /// "연결하고 파일 보기" 는 파일 패널이 열린 탭을 만든다.
    func testConnectWithFilesOpensPanel() {
        let store = WorkspaceStore.forTesting()
        var host = SSHHost()
        host.hostname = "no-such-host.invalid"

        store.connect(host)
        XCTAssertEqual(store.currentTab?.showsFilePanel, false)

        store.connect(host, showFiles: true)
        XCTAssertEqual(store.currentTab?.showsFilePanel, true)
        XCTAssertNotNil(store.currentTab?.focusedPane?.fileBrowser, "SSH 화면은 파일 탐색기를 가진다")

        store.toggleFilePanel()
        XCTAssertEqual(store.currentTab?.showsFilePanel, false)
    }

    /// 다른 탭을 왼쪽 가장자리에 놓아 합치면, 옮겨진 화면이 같은 창의 왼쪽에 붙고 원래 화면은 오른쪽으로 간다.
    func testMergedTabPaneAttachesInSameWindow() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let source = store.currentTab!
        let moved = source.panes[0]
        store.openLocalTerminal()
        let target = store.currentTab!
        let original = target.panes[0]
        show(target, store: store)

        XCTAssertTrue(store.mergeTab(source.id, into: original.id, edge: .left))
        settle()

        XCTAssertLessThan(frameInWindow(moved).maxX, W * 0.54)
        XCTAssertGreaterThan(frameInWindow(original).minX, W * 0.46)
    }

    /// ⌘D 로 생긴 선택 칸에서 대상을 고르면 그 자리에 터미널이 붙는다.
    func testPickerResolvesIntoTerminalInPlace() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!
        let first = tab.panes[0]
        show(tab, store: store)

        store.splitCurrentPane(.horizontal)
        settle()
        guard case .picker(let picker) = tab.leaves[1] else { return XCTFail("선택 칸이 생겨야 한다") }

        store.resolvePicker(picker.id, with: .local)
        settle()
        let second = tab.panes[1]
        XCTAssertLessThan(frameInWindow(first).maxX, W * 0.54)
        XCTAssertGreaterThan(frameInWindow(second).minX, W * 0.46)
    }

    /// 분할 화면 사이에는 SFTP 와 같은 두꺼운 경계 막대(좌우·위아래 모두)가 들어간다.
    func testSplitPanesAreSeparatedByThickResizeBar() {
        let a = TerminalPane(target: nil)
        let tab = TerminalTab(pane: a)
        let b = TerminalPane(target: nil)
        tab.root = tab.root.splitting(a.id, with: b, axis: .horizontal)
        let c = TerminalPane(target: nil)
        tab.root = tab.root.splitting(b.id, with: c, axis: .vertical)
        show(tab)

        let bar = PanelResizeHandle.thickness
        XCTAssertEqual(frameInWindow(b).minX - frameInWindow(a).maxX, bar, accuracy: 0.5)
        // 창 좌표는 아래가 원점: 위 화면(b)의 minY 와 아래 화면(c)의 maxY 사이 (c 의 머리줄 포함)
        XCTAssertEqual(frameInWindow(b).minY - frameInWindow(c).maxY, bar + PaneHeader.height, accuracy: 0.5)
        XCTAssertEqual(frameInWindow(a).width, frameInWindow(b).width, accuracy: 1, "반반")
    }

    /// 앱과 같이 제목 표시줄을 숨기고 자동 이동을 끈 창에 MainView 를 띄운다.
    private func showMain(_ store: WorkspaceStore) {
        window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: Self.W, height: Self.H),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView().environmentObject(store))
        window.orderFront(nil)
        settle()
    }

    /// workspace 좌표(왼쪽 위 원점)의 위치에 마우스 이벤트를 보낸다.
    private func sendMouse(_ type: NSEvent.EventType, _ p: CGPoint) {
        let height = window.contentView!.bounds.height
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: p.x, y: height - p.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        window.sendEvent(event)
        settle()
    }

    /// 탭 바의 빈 곳을 끌면 창이 움직이고, 탭을 끌면 창은 그대로다.
    func testDraggingEmptyTabBarMovesWindowButTabDragDoesNot() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!
        showMain(store)
        guard let chip = store.tabChipFrames[tab.id] else { return XCTFail() }

        // 빈 곳 (탭 목록 오른쪽) 끌기 → 창 이동
        let origin = window.frame.origin
        let empty = CGPoint(x: chip.maxX + 200, y: chip.midY)
        sendMouse(.leftMouseDown, empty)
        sendMouse(.leftMouseDragged, CGPoint(x: empty.x + 30, y: empty.y + 20))
        sendMouse(.leftMouseUp, CGPoint(x: empty.x + 30, y: empty.y + 20))
        XCTAssertEqual(window.frame.origin.x, origin.x + 30, accuracy: 1)
        XCTAssertEqual(window.frame.origin.y, origin.y - 20, accuracy: 1, "아래로 끌면 창도 아래로")

        // 탭 끌기 → 창은 그대로
        let moved = window.frame.origin
        let start = CGPoint(x: chip.minX + 20, y: chip.midY)
        sendMouse(.leftMouseDown, start)
        sendMouse(.leftMouseDragged, CGPoint(x: start.x + 40, y: start.y + 30))
        XCTAssertNotNil(store.tabDrag)
        sendMouse(.leftMouseUp, CGPoint(x: start.x + 40, y: start.y + 30))
        XCTAssertEqual(window.frame.origin, moved)
        XCTAssertNil(store.tabDrag)
    }

    /// 실제 창에서 마우스 이벤트로 탭 이름을 끌어 다른 탭 화면의 왼쪽에 놓으면 합쳐진다.
    func testDraggingTabChipWithMouseMergesIntoPane() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let target = store.currentTab!
        let targetPane = target.panes[0]
        store.openLocalTerminal()
        let source = store.currentTab!
        let sourcePane = source.panes[0]

        showMain(store)

        guard let sourceChip = store.tabChipFrames[source.id],
              let targetChip = store.tabChipFrames[target.id] else { return XCTFail("탭 이름 위치가 기록되어야 한다") }
        let send = sendMouse
        let windowOrigin = window.frame.origin

        // 짧은 클릭은 탭 선택
        send(.leftMouseDown, CGPoint(x: targetChip.minX + 20, y: targetChip.midY))
        send(.leftMouseUp, CGPoint(x: targetChip.minX + 20, y: targetChip.midY))
        XCTAssertEqual(store.selectedTab, .terminal(target.id), "클릭하면 탭 선택")
        XCTAssertNil(store.tabDrag)
        store.selectedTab = .terminal(source.id)
        settle()

        let start = CGPoint(x: sourceChip.minX + 20, y: sourceChip.midY)
        send(.leftMouseDown, start)
        send(.leftMouseDragged, CGPoint(x: start.x - 10, y: start.y))
        XCTAssertNotNil(store.tabDrag, "탭 끌기가 시작되어야 한다")
        send(.leftMouseDragged, CGPoint(x: targetChip.midX, y: targetChip.midY))
        XCTAssertEqual(store.selectedTab, .terminal(target.id), "다른 탭 이름 위 → 전환")

        guard let paneFrame = store.paneFrames[targetPane.id] else { return XCTFail("칸 위치가 기록되어야 한다") }
        let drop = CGPoint(x: paneFrame.minX + 40, y: paneFrame.midY)
        send(.leftMouseDragged, CGPoint(x: drop.x + 5, y: drop.y))
        send(.leftMouseDragged, drop)
        XCTAssertEqual(store.tabDrag?.target, PaneDropTarget(paneID: targetPane.id, edge: .left))
        send(.leftMouseUp, drop)

        XCTAssertNil(store.tabDrag)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(target.panes.map(\.id), [sourcePane.id, targetPane.id])
        XCTAssertLessThan(frameInWindow(sourcePane).maxX, W * 0.54)
        XCTAssertGreaterThan(frameInWindow(targetPane).minX, W * 0.46)
        XCTAssertEqual(window.frame.origin, windowOrigin, "탭을 끄는 동안 창은 움직이지 않는다")
    }
}
