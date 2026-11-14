import SwiftUI

/// 파일 칸 도구 막대 버튼: 아이콘 아래에 역할 이름을 붙인다.
/// 칸이 좁으면(ViewThatFits 로 showsLabel == false 쪽이 골라짐) 아이콘만 보이고, 이름은 마우스를 올리면 나오는 도움말로 본다.
struct FileToolbarButton: View {
    let symbol: String
    let label: String
    let help: String
    var showsLabel = true
    /// 켜고 끄는 버튼이 켜져 있는지 (숨김 파일 보기 등)
    var isOn = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(height: 16)
                if showsLabel {
                    Text(label)
                        .font(.system(size: 9.5))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(isOn ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, showsLabel ? 4 : 0)
            .frame(minWidth: showsLabel ? 40 : 26, minHeight: showsLabel ? 34 : 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering && isEnabled ? Theme.selection.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}
