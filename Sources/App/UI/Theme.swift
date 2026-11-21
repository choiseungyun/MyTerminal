import AppKit
import SwiftUI

/// MyTerminal 색상 팔레트. 색마다 라이트·다크 값을 함께 가지며, 앱 모양(AppearanceSettings)에 따라 자동으로 바뀐다.
/// 다른 제품의 색을 그대로 쓰지 않는다.
enum Theme {
    static let windowBackground = Color(light: 0xECEEF3, dark: 0x161925)
    static let tabBarBackground = Color(light: 0xE3E6EC, dark: 0x12141E)
    static let sidebarBackground = Color(light: 0xE9ECF1, dark: 0x1A1D2B)
    static let contentBackground = Color(light: 0xF1F3F7, dark: 0x1D2130)
    /// TerminalSettings.defaultLightColors / defaultDarkColors 와 맞춘다
    static let terminalBackground = Color(light: 0xFBFBFD, dark: 0x1B1E2B)
    static let terminalForeground = Color(light: 0x2B2F3A, dark: 0xE3E6EE)

    static let card = Color(light: 0xFFFFFF, dark: 0x252A3B)
    static let cardHover = Color(light: 0xE9EEF8, dark: 0x2E3448)
    static let field = Color(light: 0xFFFFFF, dark: 0x2A2F42)
    static let selection = Color(light: 0xD9E2F3, dark: 0x30364C)
    static let divider = Color(light: NSColor.black.withAlphaComponent(0.08),
                               dark: NSColor.white.withAlphaComponent(0.06))
    /// 분할 화면에서 포커스가 없는 화면을 흐리게 덮는 색
    static let inactivePaneOverlay = Color(light: NSColor.white.withAlphaComponent(0.35),
                                           dark: NSColor.black.withAlphaComponent(0.3))

    static let accent = Color(light: 0x3C73DE, dark: 0x5B8DEF)
    static let hostIcon = Color(light: 0x3D7BE0, dark: 0x3D7BE0)

    static let textPrimary = Color(light: 0x1C2030, dark: 0xE6E8F0)
    static let textSecondary = Color(light: 0x5B6175, dark: 0x8E94A8)
    static let textTertiary = Color(light: 0x8E93A4, dark: 0x5D6377)

    /// 분할 화면·탭을 서버별로 구분하는 색 (라이트는 밝은 배경에서 잘 보이게 조금 진하게)
    static let paneColors: [Color] = [
        Color(light: 0x3C73DE, dark: 0x5B8DEF),   // 파랑
        Color(light: 0x23935F, dark: 0x3FB98A),   // 초록
        Color(light: 0xC9701F, dark: 0xE8964A),   // 주황
        Color(light: 0x8656D0, dark: 0xA77BEA),   // 보라
        Color(light: 0xC9416F, dark: 0xE2668F),   // 분홍
        Color(light: 0x1E91A3, dark: 0x3AB7C9),   // 청록
        Color(light: 0xA88A10, dark: 0xD6B744),   // 노랑
    ]
    /// 로컬 터미널 색
    static let localPaneColor = Color(light: 0x7A8094, dark: 0x8E94A8)

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

    /// 앱 모양(라이트·다크)에 따라 바뀌는 색
    init(light: UInt32, dark: UInt32) {
        self.init(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }

    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
