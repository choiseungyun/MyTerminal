import XCTest
@testable import MyTerminal

/// 터미널 없이 분할 트리 로직만 검사하기 위한 가짜 화면
private struct FakePane: Identifiable {
    let id = UUID()
}

private typealias Tree = SplitTree<FakePane>

final class SplitTreeTests: XCTestCase {
    func testSplitAddsPaneAfterTarget() {
        let a = FakePane(), b = FakePane()
        let tree = Tree.leaf(a).splitting(a.id, with: b, axis: .horizontal)

        XCTAssertEqual(tree.panes.map(\.id), [a.id, b.id])
        guard case .split(let node) = tree else { return XCTFail("분할되지 않음") }
        XCTAssertEqual(node.axis, .horizontal)
        XCTAssertEqual(node.ratio, 0.5)
    }

    func testSplitOnlyAffectsTargetPane() {
        let a = FakePane(), b = FakePane(), c = FakePane()
        let tree = Tree.leaf(a)
            .splitting(a.id, with: b, axis: .horizontal)
            .splitting(b.id, with: c, axis: .vertical)

        // a | (b / c)
        XCTAssertEqual(tree.panes.map(\.id), [a.id, b.id, c.id])
        guard case .split(let root) = tree, case .leaf(let left) = root.first,
              case .split(let right) = root.second else { return XCTFail("구조가 다름") }
        XCTAssertEqual(left.id, a.id)
        XCTAssertEqual(right.axis, .vertical)
    }

    func testRemovingPaneCollapsesSplit() {
        let a = FakePane(), b = FakePane(), c = FakePane()
        let tree = Tree.leaf(a)
            .splitting(a.id, with: b, axis: .horizontal)
            .splitting(b.id, with: c, axis: .vertical)

        let removed = tree.removing(b.id)
        XCTAssertEqual(removed?.panes.map(\.id), [a.id, c.id])

        // 남은 a | c 는 다시 한 단계 분할이어야 한다
        guard case .split(let node)? = removed, case .leaf = node.second else {
            return XCTFail("빈 분할이 남음")
        }
    }

    func testRemovingLastPaneReturnsNil() {
        let a = FakePane()
        XCTAssertNil(Tree.leaf(a).removing(a.id))
    }

    func testRatioIsClamped() {
        let a = FakePane(), b = FakePane()
        let tree = Tree.leaf(a).splitting(a.id, with: b, axis: .horizontal)
        guard case .split(let node) = tree else { return XCTFail() }

        guard case .split(let low) = tree.settingRatio(node.id, to: -1),
              case .split(let high) = tree.settingRatio(node.id, to: 5) else { return XCTFail() }
        XCTAssertEqual(low.ratio, splitMinRatio)
        XCTAssertEqual(high.ratio, 1 - splitMinRatio)
    }

    func testEqualizeGivesSameSizeAlongAxis() {
        // a | b | c 를 a | (b | c) 로 만들면 비율이 1/3 이 되어야 한다
        let a = FakePane(), b = FakePane(), c = FakePane()
        let tree = Tree.leaf(a)
            .splitting(a.id, with: b, axis: .horizontal)
            .splitting(b.id, with: c, axis: .horizontal)
            .equalized()

        guard case .split(let root) = tree, case .split(let inner) = root.second else { return XCTFail() }
        XCTAssertEqual(root.ratio, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(inner.ratio, 0.5, accuracy: 0.0001)
    }

    func testEqualizeTreatsCrossAxisSplitAsOne() {
        // a | (b / c): 위아래 분할은 좌우 기준으로 한 칸이다
        let a = FakePane(), b = FakePane(), c = FakePane()
        let tree = Tree.leaf(a)
            .splitting(a.id, with: b, axis: .horizontal)
            .splitting(b.id, with: c, axis: .vertical)
            .equalized()

        guard case .split(let root) = tree else { return XCTFail() }
        XCTAssertEqual(root.ratio, 0.5, accuracy: 0.0001)
    }
}

final class QuickConnectTargetTests: XCTestCase {
    func testParsesUserAndHost() {
        let target = QuickConnectTarget("deploy@web-01")
        XCTAssertEqual(target?.host, "web-01")
        XCTAssertEqual(target?.user, "deploy")
        XCTAssertEqual(target?.sshCommand, "ssh deploy@web-01")
    }

    func testKeepsSshOptions() {
        let target = QuickConnectTarget("ssh -p 2222 admin@10.0.0.5")
        XCTAssertEqual(target?.host, "10.0.0.5")
        XCTAssertEqual(target?.user, "admin")
        XCTAssertEqual(target?.sshCommand, "ssh -p 2222 admin@10.0.0.5")
    }

    func testRejectsEmptyInput() {
        XCTAssertNil(QuickConnectTarget("   "))
        XCTAssertNil(QuickConnectTarget("ssh"))
    }
}
