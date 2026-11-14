import SwiftUI

/// MyTerminal 색상 팔레트 (다크 기본). 다른 제품의 색을 그대로 쓰지 않는다.
enum Theme {
    static let windowBackground = Color(hex: 0x161925)
    static let tabBarBackground = Color(hex: 0x12141E)
    static let sidebarBackground = Color(hex: 0x1A1D2B)
    static let contentBackground = Color(hex: 0x1D2130)
    static let terminalBackground = Color(hex: 0x1B1E2B)   // Resources/terminal-defaults.conf 와 맞춘다

    static let card = Color(hex: 0x252A3B)
    static let cardHover = Color(hex: 0x2E3448)
    static let field = Color(hex: 0x2A2F42)
    static let selection = Color(hex: 0x30364C)
    static let divider = Color.white.opacity(0.06)

    static let accent = Color(hex: 0x5B8DEF)
    static let hostIcon = Color(hex: 0x3D7BE0)

    static let textPrimary = Color(hex: 0xE6E8F0)
    static let textSecondary = Color(hex: 0x8E94A8)
    static let textTertiary = Color(hex: 0x5D6377)

    /// 분할 화면·탭을 서버별로 구분하는 색 (어두운 배경에서 잘 보이는 채도)
    static let paneColors: [Color] = [
        Color(hex: 0x5B8DEF),   // 파랑
        Color(hex: 0x3FB98A),   // 초록
        Color(hex: 0xE8964A),   // 주황
        Color(hex: 0xA77BEA),   // 보라
        Color(hex: 0xE2668F),   // 분홍
        Color(hex: 0x3AB7C9),   // 청록
        Color(hex: 0xD6B744),   // 노랑
    ]
    /// 로컬 터미널 색
    static let localPaneColor = Color(hex: 0x8E94A8)

    /// 접속 대상별 색. 같은 서버는 항상 같은 색 (실행할 때마다 바뀌지 않는 해시를 쓴다).
    static func paneColor(for target: SSHLaunch?) -> Color {
        guard let key = target?.title, !key.isEmpty else { return localPaneColor }
        return paneColors[paneColorIndex(for: key)]
    }

    static func paneColorIndex(for key: String) -> Int {
        var hash: UInt32 = 2166136261   // FNV-1a
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return Int(hash % UInt32(paneColors.count))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}
