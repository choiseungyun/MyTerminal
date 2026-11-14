import CoreGraphics
import Foundation

/// 분할 방향
enum SplitAxis {
    /// 좌우로 나눈다 (세로 구분선)
    case horizontal
    /// 위아래로 나눈다 (가로 구분선)
    case vertical
}

/// 터미널 탭의 화면 분할 구조
typealias PaneTree = SplitTree<PaneLeaf>
typealias PaneSplit = SplitNode<PaneLeaf>

/// 화면을 끌어다 놓을 위치 (대상 화면의 어느 가장자리)
enum DropEdge: CaseIterable {
    case left, right, top, bottom

    var axis: SplitAxis {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }

    /// 대상 화면의 앞(왼쪽·위)에 놓는지
    var placesBefore: Bool { self == .left || self == .top }

    /// 화면 안의 위치에서 가장 가까운 가장자리 (좌표는 왼쪽 위가 원점)
    static func nearest(to point: CGPoint, in size: CGSize) -> DropEdge {
        guard size.width > 0, size.height > 0 else { return .right }
        let x = point.x / size.width
        let y = point.y / size.height
        let distances: [(DropEdge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        return distances.min { $0.1 < $1.1 }!.0
    }
}

/// 화면 분할 트리. 잎(leaf)이 화면 하나다.
///
/// 값 타입이라 변경 함수는 새 트리를 돌려준다. 구조는 Ghostty 의 SplitTree 를 참고했지만
/// MyTerminal 에 필요한 기능(분할, 닫기, 비율 조절, 균등 분배, 순서 이동)만 직접 구현했다.
/// 잎 타입을 제네릭으로 둬서 실제 터미널 없이 단위 테스트할 수 있다.
indirect enum SplitTree<Leaf: Identifiable> where Leaf.ID == UUID {
    case leaf(Leaf)
    case split(SplitNode<Leaf>)

    /// 왼쪽 위부터 순서대로 모든 화면
    var panes: [Leaf] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(let split): split.first.panes + split.second.panes
        }
    }

    func contains(_ paneID: UUID) -> Bool {
        panes.contains { $0.id == paneID }
    }

    /// `paneID` 화면을 둘로 나누고, 오른쪽(또는 아래)에 `newPane` 을 놓는다.
    func splitting(_ paneID: UUID, with newPane: Leaf, axis: SplitAxis) -> SplitTree {
        inserting(.leaf(newPane), at: paneID, axis: axis, before: false)
    }

    /// `paneID` 화면을 둘로 나누고 한쪽에 `subtree`(화면 하나 또는 분할 배치 전체)를 놓는다.
    /// before: true 면 왼쪽(또는 위), false 면 오른쪽(또는 아래)
    func inserting(_ subtree: SplitTree, at paneID: UUID, axis: SplitAxis, before: Bool) -> SplitTree {
        switch self {
        case .leaf(let pane):
            guard pane.id == paneID else { return self }
            return .split(SplitNode(
                axis: axis, ratio: 0.5,
                first: before ? subtree : self,
                second: before ? self : subtree))
        case .split(var split):
            split.first = split.first.inserting(subtree, at: paneID, axis: axis, before: before)
            split.second = split.second.inserting(subtree, at: paneID, axis: axis, before: before)
            return .split(split)
        }
    }

    /// `paneID` 화면 자리에 `leaf` 를 놓는다 (배치는 그대로).
    func replacing(_ paneID: UUID, with leaf: Leaf) -> SplitTree {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? .leaf(leaf) : self
        case .split(var split):
            split.first = split.first.replacing(paneID, with: leaf)
            split.second = split.second.replacing(paneID, with: leaf)
            return .split(split)
        }
    }

    /// `paneID` 화면을 뺀 트리. 마지막 화면이었다면 nil.
    func removing(_ paneID: UUID) -> SplitTree? {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? nil : self
        case .split(var split):
            let first = split.first.removing(paneID)
            let second = split.second.removing(paneID)
            switch (first, second) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let first?, let second?):
                split.first = first
                split.second = second
                return .split(split)
            }
        }
    }

    func settingRatio(_ splitID: UUID, to ratio: CGFloat) -> SplitTree {
        switch self {
        case .leaf:
            return self
        case .split(var split):
            if split.id == splitID {
                split.ratio = min(max(ratio, splitMinRatio), 1 - splitMinRatio)
            } else {
                split.first = split.first.settingRatio(splitID, to: ratio)
                split.second = split.second.settingRatio(splitID, to: ratio)
            }
            return .split(split)
        }
    }

    /// 같은 방향으로 이어진 화면들이 같은 크기를 갖도록 비율을 맞춘다.
    func equalized() -> SplitTree {
        switch self {
        case .leaf:
            return self
        case .split(var split):
            let a = split.first.weight(along: split.axis)
            let b = split.second.weight(along: split.axis)
            split.ratio = CGFloat(a) / CGFloat(a + b)
            split.first = split.first.equalized()
            split.second = split.second.equalized()
            return .split(split)
        }
    }

    /// 같은 방향 분할에서 차지하는 칸 수 (균등 분배용)
    private func weight(along axis: SplitAxis) -> Int {
        switch self {
        case .leaf: 1
        case .split(let split):
            split.axis == axis
                ? split.first.weight(along: axis) + split.second.weight(along: axis)
                : 1
        }
    }
}

/// 한 화면이 차지할 수 있는 최소 비율
let splitMinRatio: CGFloat = 0.1

struct SplitNode<Leaf: Identifiable> where Leaf.ID == UUID {
    let id: UUID
    var axis: SplitAxis
    /// 첫 번째(왼쪽 또는 위) 화면이 차지하는 비율 (0~1)
    var ratio: CGFloat
    var first: SplitTree<Leaf>
    var second: SplitTree<Leaf>

    init(axis: SplitAxis, ratio: CGFloat, first: SplitTree<Leaf>, second: SplitTree<Leaf>) {
        self.id = UUID()
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}
