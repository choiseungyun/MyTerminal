import AppKit
import SwiftUI

/// 창 전체: 위쪽 탭 바 + 선택된 탭의 내용
struct MainView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay { TabDragOverlay().allowsHitTesting(false) }
        .coordinateSpace(name: workspaceCoordinateSpace)
        .background(Theme.windowBackground)
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            // 개발용 실행 옵션 (`open MyTerminal.app --args --open-terminal --split`)
            //   --open-terminal : 로컬 터미널 탭을 바로 연다
            //   --split         : 그 탭을 좌우로 분할한다
            //   --sftp          : SFTP 탭을 연다
            //   --quit          : 바로 종료한다 (종료 과정 확인용)
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--quit") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
            if args.contains("--sftp") { store.selectedTab = .sftp }
            if args.contains("--open-terminal"), store.tabs.isEmpty {
                store.openLocalTerminal()
                if args.contains("--split") { store.splitCurrentPane(.horizontal, choice: .same) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.selectedTab {
        case .home:
            HomeView()
        case .sftp:
            SFTPView(local: store.sftpLocal)
        case .terminal(let id):
            if let tab = store.tab(id) {
                TerminalTabView(tab: tab)
                    .id(tab.id)
            }
        }
    }
}

/// 탭을 끄는 동안 마우스를 따라다니는 탭 이름
private struct TabDragOverlay: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        GeometryReader { geo in
            if let drag = store.tabDrag, let tab = store.tab(drag.sourceTabID) {
                let origin = geo.frame(in: .named(workspaceCoordinateSpace)).origin
                let target = tab.panes.first?.target
                HStack(spacing: 6) {
                    Image(systemName: target == nil ? "terminal.fill" : "server.rack")
                        .foregroundStyle(Theme.paneColor(for: target))
                    Text(target?.title ?? "로컬")
                    if drag.target == nil {
                        Text("· \(hint(for: drag))").foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Theme.card.opacity(0.95)))
                .overlay(Capsule().stroke(Theme.accent.opacity(0.7), lineWidth: 1))
                .fixedSize()
                .position(x: drag.location.x - origin.x, y: drag.location.y - origin.y + 22)
            }
        }
    }

    /// 놓을 곳이 없을 때 안내
    private func hint(for drag: TabDrag) -> String {
        if store.tabs.count < 2 { return "합칠 다른 탭이 없습니다" }
        if store.currentTab == nil || store.currentTab?.id == drag.sourceTabID { return "합칠 탭 이름 위로 옮기세요" }
        return "화면 가장자리에 놓으면 분할"
    }
}

/// 아직 구현하지 않은 화면에 쓰는 안내
struct PlaceholderView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }
}
