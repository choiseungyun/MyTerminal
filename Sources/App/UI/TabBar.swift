import AppKit
import SwiftUI

/// 창 맨 위의 탭 바: [홈] [SFTP] [터미널 탭들...] [+]
/// 제목 표시줄 영역에 놓이므로 왼쪽은 신호등 버튼 자리로 비워 둔다.
struct TabBar: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 72)   // 신호등 버튼 자리

            TabChip(symbol: "square.grid.2x2.fill", title: "홈", isSelected: store.selectedTab == .home) {
                store.selectedTab = .home
            }
            TabChip(symbol: "folder.fill", title: "SFTP", isSelected: store.selectedTab == .sftp) {
                store.selectedTab = .sftp
            }

            if !store.tabs.isEmpty {
                Rectangle().fill(Theme.divider).frame(width: 1, height: 18).padding(.horizontal, 2)
            }

            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.tabs) { tab in
                            TerminalTabChip(tab: tab)
                        }
                    }
                    // 탭 뒤의 빈 곳도 끌어서 창을 옮길 수 있게 (스크롤 영역이 클릭을 가져가므로)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .leading)
                    .background(WindowDragArea())
                }
            }

            Button {
                store.openLocalTerminal()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("새 로컬 터미널 (⌘T)")

            Spacer(minLength: 12)

            if let tab = store.currentTab {
                FilePanelButton(tab: tab)
            }
        }
        .padding(.trailing, 10)
        .frame(height: 46)
        .background(WindowDragArea())
        .background(Theme.tabBarBackground)
    }
}

private struct TabChip: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Theme.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalTabChip: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var tab: TerminalTab
    @State private var hovering = false

    private var isSelected: Bool { store.selectedTab == .terminal(tab.id) }
    /// 탭 제목은 첫 화면의 접속 대상으로 정한다.
    private var target: SSHLaunch? { tab.panes.first?.target }

    var body: some View {
        HStack(spacing: 7) {
            label
                .padding(.leading, 12)
                .frame(height: 30)
                .contentShape(Rectangle())
                // 이름 부분: 클릭하면 선택, 끌면 다른 탭 화면에 합치기 (AppKit 으로 마우스를 직접 처리)
                .overlay(
                    GeometryReader { geo in
                        TabDragHandle(
                            workspaceFrame: geo.frame(in: .named(workspaceCoordinateSpace)),
                            onClick: { store.selectedTab = .terminal(tab.id) },
                            onDrag: { store.updateTabDrag(tab.id, at: $0) },
                            onEnd: { store.endTabDrag() })
                    })
            Button {
                store.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
            .help("탭 닫기 (⌘W)")
        }
        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.selection : (hovering ? Theme.card : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture { store.selectedTab = .terminal(tab.id) }
        .onHover { hovering = $0 }
        .help("끌어서 다른 탭의 화면 가장자리에 놓으면 분할로 합쳐집니다")
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named(workspaceCoordinateSpace))
                Color.clear
                    .onAppear { store.tabChipFrames[tab.id] = frame }
                    .onChange(of: frame) { _, newFrame in store.tabChipFrames[tab.id] = newFrame }
            })
        .opacity(store.tabDrag?.sourceTabID == tab.id ? 0.5 : 1)
    }

    private var label: some View {
        HStack(spacing: 7) {
            Image(systemName: target == nil ? "terminal.fill" : "server.rack")
                .font(.system(size: 11))
                .foregroundStyle(Theme.paneColor(for: target))
            Text(target?.title ?? "로컬")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            if tab.leaves.count > 1 {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// 탭 이름 위의 투명한 AppKit 화면: 클릭·끌기를 직접 처리한다.
///
/// 탭 바는 숨긴 제목 표시줄 영역에 있어서 SwiftUI 끌기·시스템 끌어 놓기가 창 옮기기나
/// 터미널 화면(NSView)에 가로막힐 수 있다. 마우스를 누른 화면이 끝까지 이벤트를 받는 AppKit 방식으로
/// 창 어디로 끌든 위치를 받아 store 에 알린다.
struct TabDragHandle: NSViewRepresentable {
    /// 이 화면의 workspace 좌표 위치 (마우스 위치를 workspace 좌표로 바꾸는 데 쓴다)
    let workspaceFrame: CGRect
    let onClick: () -> Void
    let onDrag: (CGPoint) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> TabDragHandleView { TabDragHandleView() }

    func updateNSView(_ view: TabDragHandleView, context: Context) {
        view.workspaceFrame = workspaceFrame
        view.onClick = onClick
        view.onDrag = onDrag
        view.onEnd = onEnd
    }
}

final class TabDragHandleView: NSView {
    /// 이만큼 움직여야 끌기로 본다 (그보다 적으면 클릭)
    static let dragThreshold: CGFloat = 5

    var workspaceFrame: CGRect = .zero
    var onClick: () -> Void = {}
    var onDrag: (CGPoint) -> Void = { _ in }
    var onEnd: () -> Void = {}

    private var downPoint: CGPoint?
    private var dragging = false

    override var isFlipped: Bool { true }
    /// 제목 표시줄 영역이어도 창을 옮기지 않는다
    override var mouseDownCanMoveWindow: Bool { false }
    /// 창이 활성 상태가 아니어도 첫 클릭부터 받는다
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragging {
            guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= Self.dragThreshold else { return }
            dragging = true
            NSCursor.closedHand.push()
        }
        onDrag(CGPoint(x: workspaceFrame.minX + point.x, y: workspaceFrame.minY + point.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            downPoint = nil
            dragging = false
        }
        if dragging {
            NSCursor.pop()
            onEnd()
        } else if downPoint != nil {
            onClick()
        }
    }
}

/// 제목 표시줄을 숨긴 창에서 탭 바의 빈 곳을 끌어 창을 옮길 수 있게 한다.
///
/// 창의 자동 이동(isMovable)은 꺼 두었다(AppDelegate). 자동 이동은 탭 바 전체를 이동 영역으로 잡아
/// 탭을 끌 때도 창이 움직이기 때문이다. 대신 이 화면을 직접 누른 경우(탭·버튼이 없는 빈 곳)에만 창을 옮긴다.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        private var startMouse: CGPoint?
        private var startOrigin: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // 빈 곳을 더블클릭하면 창 확대/복원 (macOS 기본 동작과 같게)
            if event.clickCount == 2 {
                window?.performZoom(nil)
                return
            }
            startMouse = Self.screenLocation(of: event)
            startOrigin = window?.frame.origin
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let startMouse, let startOrigin, let mouse = Self.screenLocation(of: event) else { return }
            // 화면 좌표(CG)는 위가 원점이라 y 는 반대로
            window.setFrameOrigin(NSPoint(
                x: startOrigin.x + mouse.x - startMouse.x,
                y: startOrigin.y - (mouse.y - startMouse.y)))
        }

        /// 이벤트가 생긴 순간의 화면 위치 (창이 움직여도 흔들리지 않는다)
        private static func screenLocation(of event: NSEvent) -> NSPoint? {
            event.cgEvent?.location
        }

        override func mouseUp(with event: NSEvent) {
            startMouse = nil
            startOrigin = nil
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 탭 바 오른쪽의 SFTP(파일 패널) 버튼. 터미널 탭에서만 보인다.
private struct FilePanelButton: View {
    @ObservedObject var tab: TerminalTab
    @State private var hovering = false

    private var isOpen: Bool { tab.showsFilePanel }
    private var isSSH: Bool { tab.focusedPane?.target != nil }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { tab.showsFilePanel.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "folder.fill" : "folder")
                    .font(.system(size: 12))
                Text("SFTP").font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(isOpen ? Color.white : (isSSH ? Theme.textPrimary : Theme.textTertiary))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isOpen ? Theme.accent : (hovering ? Theme.card : Theme.selection.opacity(0.6))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isSSH ? "서버 파일 패널 보이기·숨기기 (⌥⌘F)" : "SSH 화면에서 서버 파일을 볼 수 있습니다 (⌥⌘F)")
        .padding(.trailing, 6)
    }
}
