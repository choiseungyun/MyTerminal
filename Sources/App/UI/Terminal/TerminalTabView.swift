import AppKit
import SwiftUI

/// 터미널 탭: 분할된 터미널 화면들 + 아래 상태 줄
struct TerminalTabView: View {
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var store: WorkspaceStore
    /// 파일 패널 폭 (끌어서 조절, 앱 전체에서 기억)
    @AppStorage("filePanel.width") private var filePanelWidth = PanelResizeHandle.defaultWidth

    var body: some View {
        GeometryReader { geo in
            content(maxPanelWidth: max(PanelResizeHandle.minWidth, geo.size.width * 0.75))
        }
    }

    private func content(maxPanelWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PaneTreeView(tree: tab.root, tab: tab)
                    .background(Theme.terminalBackground)
                    .overlay { AIOverlays(ai: store.ai, tabID: tab.id) }

                Rectangle().fill(Theme.divider).frame(height: 1)

                if let pane = tab.focusedPane {
                    StatusBar(pane: pane, paneCount: tab.leaves.count, tab: tab)
                        .id(pane.id)
                }
            }

            if tab.showsFilePanel {
                PanelResizeHandle(width: $filePanelWidth, maxWidth: maxPanelWidth)
                filePanel
                    .frame(width: min(max(filePanelWidth, PanelResizeHandle.minWidth), maxPanelWidth))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
    }

    /// 포커스된 화면의 서버 파일. 로컬 화면이면 안내만 보여 준다.
    @ViewBuilder
    private var filePanel: some View {
        if let pane = tab.focusedPane, let browser = pane.fileBrowser {
            FileBrowserPanel(browser: browser, title: pane.target?.title ?? "", onClose: close)
                .id(pane.id)
        } else {
            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    Button(action: close) { Image(systemName: "arrow.right.to.line") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .help("패널 닫기")
                }
                Spacer()
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.textTertiary)
                Text("로컬 터미널입니다.\nSSH 화면을 선택하면 그 서버의 파일이 보입니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.sidebarBackground)
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { tab.showsFilePanel = false }
    }
}

/// 분할 트리를 재귀적으로 그린다.
private struct PaneTreeView: View {
    let tree: PaneTree
    @ObservedObject var tab: TerminalTab

    var body: some View {
        switch tree {
        case .leaf(let leaf):
            LeafView(leaf: leaf, tab: tab)
                .id(leaf.id)
        case .split(let split):
            SplitContainer(split: split, tab: tab)
        }
    }
}

/// 두 화면과 그 사이의 경계 막대. 막대를 끌어 비율을 바꾸고, 더블클릭하면 반반.
/// 막대는 SFTP 화면과 같은 두꺼운 막대(ResizeBar)를 쓴다.
private struct SplitContainer: View {
    let split: PaneSplit
    @ObservedObject var tab: TerminalTab
    /// 끌기 시작할 때의 비율
    @State private var startRatio: CGFloat?

    private static let barThickness = PanelResizeHandle.thickness

    var body: some View {
        GeometryReader { geo in
            let horizontal = split.axis == .horizontal
            let total = horizontal ? geo.size.width : geo.size.height
            let available = max(0, total - Self.barThickness)
            let firstLength = available * split.ratio
            let secondLength = max(0, available - firstLength)

            let bar = ResizeBar(
                axis: split.axis,
                help: "끌어서 크기 조절 · 더블클릭: 반반",
                onChanged: { delta in
                    guard available > 0 else { return }
                    let start = startRatio ?? split.ratio
                    startRatio = start
                    tab.root = tab.root.settingRatio(split.id, to: start + delta / available)
                },
                onEnded: { startRatio = nil },
                onReset: { tab.root = tab.root.settingRatio(split.id, to: 0.5) })

            if horizontal {
                HStack(spacing: 0) {
                    PaneTreeView(tree: split.first, tab: tab).frame(width: firstLength)
                    bar
                    PaneTreeView(tree: split.second, tab: tab).frame(width: secondLength)
                }
            } else {
                VStack(spacing: 0) {
                    PaneTreeView(tree: split.first, tab: tab).frame(height: firstLength)
                    bar
                    PaneTreeView(tree: split.second, tab: tab).frame(height: secondLength)
                }
            }
        }
    }
}

/// 분할 칸 하나 + 다른 탭을 끌어다 놓는 영역
private struct LeafView: View {
    let leaf: PaneLeaf
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var store: WorkspaceStore

    /// 끌고 있는 탭을 놓으면 들어갈 가장자리 (이 칸 위가 아니면 nil)
    private var dropEdge: DropEdge? {
        guard let target = store.tabDrag?.target, target.paneID == leaf.id else { return nil }
        return target.edge
    }

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(workspaceCoordinateSpace))
            content
                .overlay { DropPreview(edge: dropEdge).allowsHitTesting(false) }
                .onAppear { store.paneFrames[leaf.id] = frame }
                .onChange(of: frame) { _, newFrame in store.paneFrames[leaf.id] = newFrame }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch leaf {
        case .terminal(let pane): PaneView(pane: pane, tab: tab)
        case .picker(let picker): PanePickerView(picker: picker, tab: tab)
        }
    }
}

/// 탭을 놓을 자리 미리 보기: 대상 칸의 절반을 파랗게 칠한다.
private struct DropPreview: View {
    let edge: DropEdge?

    var body: some View {
        GeometryReader { geo in
            if let edge {
                let half = CGSize(
                    width: edge.axis == .horizontal ? geo.size.width / 2 : geo.size.width,
                    height: edge.axis == .vertical ? geo.size.height / 2 : geo.size.height)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 2))
                    .padding(4)
                    .frame(width: half.width, height: half.height)
                    .offset(
                        x: edge == .right ? geo.size.width / 2 : 0,
                        y: edge == .bottom ? geo.size.height / 2 : 0)
                    .animation(.easeOut(duration: 0.12), value: edge)
            }
        }
    }
}

/// 터미널 화면 하나. 분할되어 있으면 서버별 색의 머리줄을 달고, 포커스가 없으면 어둡게 한다.
private struct PaneView: View {
    @ObservedObject var pane: TerminalPane
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var store: WorkspaceStore

    private var isFocused: Bool { tab.focusedPaneID == pane.id }
    private var isSplit: Bool { tab.leaves.count > 1 }
    private var color: Color { Theme.paneColor(for: pane.target) }

    var body: some View {
        VStack(spacing: 0) {
            if isSplit {
                PaneHeader(pane: pane, color: color, isFocused: isFocused) {
                    store.closePane(pane.id)
                } onSelect: {
                    tab.focusedPaneID = pane.id
                }
            }
            TerminalSurface(view: pane.view, isFocused: isFocused)
                .overlay(
                    Theme.inactivePaneOverlay
                        .opacity(isFocused || !isSplit ? 0 : 1)
                        .allowsHitTesting(false))
        }
        // 포커스된 화면은 서버 색 테두리
        .overlay(
            Rectangle()
                .strokeBorder(color, lineWidth: 2)
                .opacity(isFocused && isSplit ? 0.9 : 0)
                .allowsHitTesting(false))
    }
}

/// 분할 화면 위의 얇은 머리줄: 서버 색 점, 이름, 닫기
struct PaneHeader: View {
    static let height: CGFloat = 24

    @ObservedObject var pane: TerminalPane
    let color: Color
    let isFocused: Bool
    let onClose: () -> Void
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Image(systemName: pane.target == nil ? "terminal" : "server.rack")
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(pane.target?.title ?? "로컬")
                .font(.system(size: 11.5, weight: isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
            if let pwd = pane.pwd {
                Text(pwd)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .opacity(hovering || isFocused ? 1 : 0)
            .help("화면 닫기 (⌘W)")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(
            ZStack {
                Theme.tabBarBackground
                color.opacity(isFocused ? 0.28 : 0.10)
            })
        .overlay(alignment: .bottom) { Rectangle().fill(color.opacity(isFocused ? 0.8 : 0.3)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

private struct StatusBar: View {
    @ObservedObject var pane: TerminalPane
    let paneCount: Int
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pane.target == nil ? "terminal" : "server.rack")
            Text(pane.target?.displayCommand ?? "로컬")
            if let pwd = pane.pwd {
                Text("·")
                Text(pwd).lineLimit(1).truncationMode(.middle)
            }
            if paneCount > 1 {
                Text("· 화면 \(paneCount)개")
            }
            Spacer()
            aiButton
            Text("⌘K AI · ⌘D 분할 · 탭을 화면으로 끌면 합치기")
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            if paneCount > 1, tab.focusedPaneID == pane.id {
                Button {
                    store.detachPane(pane.id)
                } label: {
                    Label("새 탭으로", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.plain)
                .help("이 화면을 새 탭으로 분리 (접속 유지)")
            }
            Button {
                withAnimation(.easeOut(duration: 0.2)) { tab.showsFilePanel.toggle() }
            } label: {
                Label("파일", systemImage: tab.showsFilePanel ? "folder.fill" : "folder")
                    .foregroundStyle(tab.showsFilePanel ? Theme.textPrimary : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("서버 파일 패널 (⌥⌘F)")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.tabBarBackground)
    }

    /// 상황에 맞는 AI 버튼: 접속 실패 진단 > 실패한 명령 설명 > 명령 추천
    @ViewBuilder
    private var aiButton: some View {
        if let code = pane.connectionFailure {
            aiChip("접속 실패 진단", help: "ssh 가 오류로 끝났습니다 (종료 코드 \(code)). AI 로 원인을 찾습니다.", highlighted: true) {
                store.diagnoseConnection(pane.id)
            }
        } else if let code = pane.lastFailedExitCode {
            aiChip("왜 실패했나요?", help: "마지막 명령이 종료 코드 \(code) 로 실패했습니다. AI 로 원인을 찾습니다 (⇧⌘E).", highlighted: true) {
                store.explainFailure(pane.id)
            }
        } else {
            aiChip("AI", help: "AI 명령 추천 (⌘K) · 선택한 내용 설명 (⇧⌘E)", highlighted: false) {
                store.focus(pane.id)
                store.openAIPalette()
            }
        }
    }

    private func aiChip(_ title: String, help: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "sparkles")
                .foregroundStyle(highlighted ? Color.white : Theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(highlighted ? Theme.accent : Color.clear))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// TerminalSurfaceView 를 SwiftUI 에 넣는다.
/// 탭 전환·분할로 위치가 바뀌어도 같은 NSView 를 옮겨 붙이므로 셸 세션이 유지된다.
///
/// 분할 화면을 닫으면 남은 화면의 위치(트리 구조)가 바뀌어 SwiftUI 가 새 컨테이너를 만든다.
/// 이때 사라질 옛 컨테이너도 한 번 더 갱신되므로, 화면의 주인(`TerminalSurfaceView.host`)인
/// 컨테이너만 화면을 붙이게 한다. 주인이 없으면 이렇게 하지 않으면 옛 컨테이너가 화면을 가져간 채 사라진다.
struct TerminalSurface: NSViewRepresentable {
    let view: TerminalSurfaceView
    let isFocused: Bool

    func makeNSView(context: Context) -> TerminalSurfaceHost {
        let host = TerminalSurfaceHost(surfaceView: view)
        view.host = host
        host.wantsFocus = isFocused
        host.attachIfOwner()
        return host
    }

    func updateNSView(_ host: TerminalSurfaceHost, context: Context) {
        // 주인이 사라졌으면(닫힌 컨테이너) 남아 있는 컨테이너가 이어받는다.
        if view.host == nil { view.host = host }
        host.wantsFocus = isFocused
        host.attachIfOwner()
    }

    static func dismantleNSView(_ host: TerminalSurfaceHost, coordinator: ()) {
        if host.surfaceView.host === host { host.surfaceView.host = nil }
    }
}

/// TerminalSurfaceView 를 담는 컨테이너. 창에 붙을 때 자기가 주인이면 화면을 붙이고 포커스를 준다.
final class TerminalSurfaceHost: NSView {
    let surfaceView: TerminalSurfaceView
    var wantsFocus = false

    init(surfaceView: TerminalSurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 이 컨테이너가 주인일 때만 화면을 붙인다.
    func attachIfOwner() {
        guard surfaceView.host === self else { return }
        if surfaceView.superview !== self {
            surfaceView.removeFromSuperview()
            surfaceView.frame = bounds
            surfaceView.autoresizingMask = [.width, .height]
            addSubview(surfaceView)
        }
        focusIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attachIfOwner() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if surfaceView.superview === self { surfaceView.frame = bounds }
    }

    /// 화면에 붙은 뒤 키 입력 포커스를 준다.
    private func focusIfNeeded() {
        guard wantsFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, self.surfaceView.superview === self,
                  let window = self.window, window.firstResponder !== self.surfaceView else { return }
            window.makeFirstResponder(self.surfaceView)
        }
    }
}

/// 오른쪽 패널 왼쪽 경계선. 끌어서 폭을 바꾸고, 더블클릭하면 기본 폭.
struct PanelResizeHandle: View {
    static let defaultWidth: Double = 340
    static let minWidth: CGFloat = 260
    /// 막대 두께 (잡기 쉽도록)
    static let thickness: CGFloat = 8

    @Binding var width: Double
    let maxWidth: CGFloat
    @State private var startWidth: Double?

    var body: some View {
        ResizeBar(
            help: "끌어서 폭 조절 · 더블클릭: 기본 폭",
            onChanged: { dx in
                let start = startWidth ?? width
                startWidth = start
                // 패널은 오른쪽에 있으므로 왼쪽으로 끌면 넓어진다
                width = min(max(start - Double(dx), Double(Self.minWidth)), Double(maxWidth))
            },
            onEnded: { startWidth = nil },
            onReset: { width = Self.defaultWidth })
    }
}

/// 두 영역 사이의 두꺼운 경계 막대 (가운데 손잡이, 마우스를 올리거나 끄는 동안 파랗게).
/// axis 가 .horizontal 이면 좌우 영역 사이의 세로 막대, .vertical 이면 위아래 영역 사이의 가로 막대.
/// onChanged 에는 끌기 시작점부터 막대에 수직 방향으로 움직인 거리가 온다.
struct ResizeBar: View {
    var axis: SplitAxis = .horizontal
    let help: String
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onReset: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    private var active: Bool { hovering || dragging }
    private var vertical: Bool { axis == .horizontal }
    private var thickness: CGFloat { PanelResizeHandle.thickness }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(active ? Theme.accent.opacity(0.35) : Theme.tabBarBackground)
            Capsule()
                .fill(active ? Theme.accent : Theme.textTertiary.opacity(0.8))
                .frame(width: vertical ? 3 : 40, height: vertical ? 40 : 3)
        }
        .frame(width: vertical ? thickness : nil, height: vertical ? nil : thickness)
        .overlay(alignment: vertical ? .leading : .top) {
            Rectangle().fill(Theme.divider).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        }
        .overlay(alignment: vertical ? .trailing : .bottom) {
            Rectangle().fill(Theme.divider).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    onChanged(vertical ? value.translation.width : value.translation.height)
                }
                .onEnded { _ in
                    dragging = false
                    onEnded()
                })
        .onTapGesture(count: 2, perform: onReset)
        .animation(.easeOut(duration: 0.12), value: active)
        .help(help)
    }
}
