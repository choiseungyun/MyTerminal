import SwiftUI

/// 왼쪽 메뉴 항목
enum SidebarItem: String, CaseIterable, Identifiable {
    case hosts, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hosts: "호스트"
        case .history: "히스토리"
        }
    }

    var symbol: String {
        switch self {
        case .hosts: "server.rack"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// 홈 탭: 왼쪽 메뉴 + 오른쪽 내용
struct HomeView: View {
    @State private var selection: SidebarItem = .hosts

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection)
            Rectangle().fill(Theme.divider).frame(width: 1)
            Group {
                switch selection {
                case .hosts: HostsView()
                case .history: HistoryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: SidebarItem
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SidebarItem.allCases) { item in
                SidebarRow(symbol: item.symbol, title: item.title, isSelected: selection == item) {
                    selection = item
                }
            }
            Spacer()
            SidebarRow(symbol: "gearshape", title: "설정", isSelected: false) { openSettings() }
                .help("설정 (⌘,)")
        }
        .padding(12)
        .frame(width: 220)
        .background(Theme.sidebarBackground)
    }
}

private struct SidebarRow: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Theme.selection : (hovering ? Theme.card.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
