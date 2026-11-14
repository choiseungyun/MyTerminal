import XCTest
@testable import MyTerminal

/// 분할 대상 고르기(선택 칸)와 탭 합치기·분리
final class SplitMergeTests: XCTestCase {
    private struct Leaf: Identifiable { let id = UUID() }

    // MARK: 분할 트리

    func testInsertingSubtreeBeforeAndAfter() {
        let a = Leaf(), b = Leaf(), c = Leaf()
        let tree = SplitTree.leaf(a)
        let other = SplitTree.leaf(b).splitting(b.id, with: c, axis: .vertical)

        let before = tree.inserting(other, at: a.id, axis: .horizontal, before: true)
        XCTAssertEqual(before.panes.map(\.id), [b.id, c.id, a.id])
        let after = tree.inserting(other, at: a.id, axis: .horizontal, before: false)
        XCTAssertEqual(after.panes.map(\.id), [a.id, b.id, c.id])
        guard case .split(let split) = after, case .split(let inner) = split.second else {
            return XCTFail("옮긴 배치가 그대로 들어가야 한다")
        }
        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(inner.axis, .vertical)
    }

    func testReplacingKeepsLayout() {
        let a = Leaf(), b = Leaf(), c = Leaf()
        let tree = SplitTree.leaf(a).splitting(a.id, with: b, axis: .horizontal)
        let replaced = tree.replacing(b.id, with: c)
        XCTAssertEqual(replaced.panes.map(\.id), [a.id, c.id])
    }

    func testNearestEdge() {
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(DropEdge.nearest(to: CGPoint(x: 20, y: 100), in: size), .left)
        XCTAssertEqual(DropEdge.nearest(to: CGPoint(x: 390, y: 100), in: size), .right)
        XCTAssertEqual(DropEdge.nearest(to: CGPoint(x: 200, y: 10), in: size), .top)
        XCTAssertEqual(DropEdge.nearest(to: CGPoint(x: 200, y: 190), in: size), .bottom)
        XCTAssertEqual(DropEdge.left.axis, .horizontal)
        XCTAssertTrue(DropEdge.top.placesBefore)
        XCTAssertFalse(DropEdge.bottom.placesBefore)
    }

    /// 탭 끌기: 다른 탭 이름 위 → 전환, 칸 위 → 가장자리, 놓으면 합치기
    func testTabDragSwitchesTabAndMergesAtEdge() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let target = store.currentTab!
        let targetPane = target.panes[0]
        store.openLocalTerminal()
        let source = store.currentTab!

        store.tabChipFrames[target.id] = CGRect(x: 100, y: 10, width: 120, height: 30)
        store.tabChipFrames[source.id] = CGRect(x: 230, y: 10, width: 120, height: 30)
        store.paneFrames[targetPane.id] = CGRect(x: 0, y: 50, width: 1000, height: 600)

        store.updateTabDrag(source.id, at: CGPoint(x: 300, y: 20))
        XCTAssertEqual(store.selectedTab, .terminal(target.id), "보던 탭을 끌기 시작하면 바로 전 탭을 보여 준다")
        XCTAssertNil(store.tabDrag?.target)

        store.updateTabDrag(source.id, at: CGPoint(x: 150, y: 20))
        XCTAssertEqual(store.selectedTab, .terminal(target.id))

        store.updateTabDrag(source.id, at: CGPoint(x: 500, y: 620))
        XCTAssertEqual(store.tabDrag?.target, PaneDropTarget(paneID: targetPane.id, edge: .bottom))

        XCTAssertTrue(store.endTabDrag())
        XCTAssertNil(store.tabDrag)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(target.leaves.count, 2)
        guard case .split(let split) = target.root else { return XCTFail() }
        XCTAssertEqual(split.axis, .vertical)
        XCTAssertTrue(target.panes[0] === targetPane)
        XCTAssertNil(store.tabChipFrames[source.id], "사라진 탭 위치 정리")
    }

    /// 다른 탭 이름 위에 올리면 그 탭으로 전환, 놓지 않고 끝내면 처음 보던 탭으로 돌아간다.
    func testTabDragHoverSwitchesAndCancelRestoresSelection() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let a = store.currentTab!
        store.openLocalTerminal()
        let b = store.currentTab!
        store.openLocalTerminal()
        let c = store.currentTab!
        store.tabChipFrames[a.id] = CGRect(x: 100, y: 10, width: 100, height: 30)
        store.tabChipFrames[b.id] = CGRect(x: 210, y: 10, width: 100, height: 30)
        store.tabChipFrames[c.id] = CGRect(x: 320, y: 10, width: 100, height: 30)

        // c 를 보면서 a 를 끈다 → 보이는 c 에 바로 놓을 수 있으므로 전환하지 않는다
        store.updateTabDrag(a.id, at: CGPoint(x: 150, y: 60))
        XCTAssertEqual(store.selectedTab, .terminal(c.id))
        store.updateTabDrag(a.id, at: CGPoint(x: 250, y: 20))
        XCTAssertEqual(store.selectedTab, .terminal(b.id), "b 이름 위 → b")
        XCTAssertFalse(store.endTabDrag())
        XCTAssertEqual(store.selectedTab, .terminal(c.id), "합치지 않으면 처음 보던 c 로")
        XCTAssertEqual(store.tabs.count, 3)
    }

    /// 칸 밖에서 놓거나 자기 탭 위에서 놓으면 아무 일도 없다.
    func testTabDragOutsidePaneDoesNothing() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!
        store.paneFrames[tab.panes[0].id] = CGRect(x: 0, y: 50, width: 1000, height: 600)

        store.updateTabDrag(tab.id, at: CGPoint(x: 500, y: 300))
        XCTAssertNil(store.tabDrag?.target, "자기 탭 화면에는 놓을 수 없다")
        XCTAssertFalse(store.endTabDrag())
        XCTAssertEqual(tab.leaves.count, 1)
        XCTAssertEqual(store.tabs.count, 1)
    }

    // MARK: 선택 칸

    func testSplitWithoutChoiceInsertsPicker() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!

        store.splitCurrentPane(.horizontal)
        XCTAssertEqual(tab.leaves.count, 2)
        XCTAssertEqual(tab.panes.count, 1, "선택 칸은 터미널이 아니다")
        guard case .picker(let picker) = tab.leaves[1] else { return XCTFail() }
        XCTAssertEqual(tab.focusedPaneID, picker.id)

        store.resolvePicker(picker.id, with: .same)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.focusedPaneID, tab.panes[1].id)
        XCTAssertNil(tab.panes[1].target)
    }

    func testCancelPickerRestoresFocus() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!
        let first = tab.panes[0]

        store.splitCurrentPane(.vertical)
        store.closeCurrentPane()   // ⌘W / Esc
        XCTAssertEqual(tab.leaves.count, 1)
        XCTAssertEqual(tab.focusedPaneID, first.id)
        XCTAssertEqual(store.tabs.count, 1)
    }

    func testQuickChoiceConnectsAndRemembers() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!
        let target = QuickConnectTarget("deploy@no-such-host.invalid")!

        store.splitCurrentPane(.horizontal, choice: .quick(target))
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.panes[1].target?.title, "no-such-host.invalid")
        XCTAssertNotNil(tab.panes[1].historyID)
        XCTAssertEqual(store.recentTargets.first, target)
        store.closeTab(tab.id)
    }

    func testPickerOptions() {
        let local = PanePicker(originTarget: nil, originDirectory: "/tmp")
        let localOptions = PanePickerOption.options(for: local, query: "", hosts: [])
        XCTAssertEqual(localOptions.map(\.id), ["same"], "로컬에서 나누면 로컬 하나")

        let remote = PanePicker(
            originTarget: SSHCommand.launch(for: QuickConnectTarget("a@web")!), originDirectory: nil)
        var host = SSHHost()
        host.name = "db-main"
        host.hostname = "db.internal"
        let all = PanePickerOption.options(for: remote, query: "", hosts: [host])
        XCTAssertEqual(all.map(\.id), ["same", "local", host.id.uuidString], "Enter = 같은 서버")

        let searched = PanePickerOption.options(for: remote, query: "db", hosts: [host])
        XCTAssertEqual(searched.map(\.id), [host.id.uuidString])

        let quick = PanePickerOption.options(for: remote, query: "root@10.0.0.9", hosts: [host])
        XCTAssertEqual(quick.first?.id, "quick")

        let unknown = PanePickerOption.options(for: remote, query: "web-02", hosts: [host])
        XCTAssertEqual(unknown.map(\.id), ["quick"], "일치하는 호스트가 없으면 바로 접속 제안")
    }

    // MARK: 탭 합치기·분리

    func testMergeTabMovesWholeLayoutWithoutEndingHistory() {
        let store = WorkspaceStore.forTesting()
        let target = QuickConnectTarget("deploy@no-such-host.invalid")!
        store.connect(target)
        let source = store.currentTab!
        store.splitCurrentPane(.vertical, choice: .local)
        let movedPanes = source.panes
        let historyID = movedPanes[0].historyID

        store.openLocalTerminal()
        let dest = store.currentTab!
        let destPane = dest.panes[0]

        XCTAssertTrue(store.mergeTab(source.id, into: destPane.id, edge: .right))
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNil(store.tab(source.id))
        XCTAssertEqual(store.selectedTab, .terminal(dest.id))
        XCTAssertTrue(dest.panes[0] === destPane)
        XCTAssertTrue(dest.panes[1] === movedPanes[0], "같은 화면 객체(세션)가 옮겨진다")
        XCTAssertTrue(dest.panes[2] === movedPanes[1])
        XCTAssertEqual(dest.focusedPaneID, movedPanes[1].id)

        let record = store.history.records.first { $0.id == historyID }
        XCTAssertNotNil(record)
        XCTAssertNil(record?.endedAt, "합쳐도 접속은 이어진다")
        XCTAssertTrue(store.isOpen(record!))
        store.closeTab(dest.id)
    }

    func testMergeIntoSameTabIsRejected() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!
        XCTAssertFalse(store.mergeTab(tab.id, into: tab.panes[0].id, edge: .left))
        XCTAssertEqual(tab.leaves.count, 1)
    }

    func testDetachPaneIntoNewTab() {
        let store = WorkspaceStore.forTesting()
        store.openLocalTerminal()
        let tab = store.currentTab!
        store.splitCurrentPane(.horizontal, choice: .same)
        let second = tab.panes[1]
        store.openLocalTerminal()
        let last = store.currentTab!
        store.selectedTab = .terminal(tab.id)
        XCTAssertTrue(store.canDetachCurrentPane)

        store.detachCurrentPane()
        XCTAssertEqual(store.tabs.count, 3)
        XCTAssertTrue(store.tabs[2] === last, "새 탭은 원래 탭 바로 뒤에")
        let newTab = store.tabs[1]
        XCTAssertTrue(newTab.panes[0] === second)
        XCTAssertEqual(store.selectedTab, .terminal(newTab.id))
        XCTAssertEqual(tab.leaves.count, 1)
        XCTAssertEqual(tab.focusedPaneID, tab.panes[0].id)

        XCTAssertFalse(store.detachPane(second.id), "화면이 하나뿐인 탭은 분리하지 않는다")
    }
}

final class PaneColorTests: XCTestCase {
    /// 같은 서버는 항상 같은 색, 문자열 해시가 실행마다 바뀌지 않는다.
    func testPaneColorIndexIsStable() {
        XCTAssertEqual(Theme.paneColorIndex(for: "web-01"), Theme.paneColorIndex(for: "web-01"))
        // FNV-1a 고정값 (실행마다 같아야 한다)
        XCTAssertEqual(Theme.paneColorIndex(for: "a"), Int(0xE40C292C as UInt32 % UInt32(Theme.paneColors.count)))
        let indices = Set(["web-01", "web-02", "db-main", "bastion", "cache", "api", "batch"].map(Theme.paneColorIndex))
        XCTAssertGreaterThan(indices.count, 2, "여러 서버가 한 색으로 몰리지 않는다")
    }
}
