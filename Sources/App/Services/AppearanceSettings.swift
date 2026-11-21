import AppKit
import Combine
import Foundation

/// 앱 화면 모양 (시스템 설정 따라가기 · 라이트 · 다크).
///
/// `NSApp.appearance` 로 적용하므로 메인 창, 설정 창, 메뉴, 경고창이 모두 같이 바뀐다.
/// UI 색(Theme)은 라이트·다크 값을 함께 가진 색이라 따로 다시 그릴 필요가 없다.
/// 터미널 색이 "MyTerminal 기본" 이면 터미널도 밝은·어두운 기본 색으로 바꾼다 (TerminalSettings).
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "시스템"
            case .light: "라이트"
            case .dark: "다크"
            }
        }

        /// nil = 시스템 설정을 따른다
        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// 기본값은 다크 (처음부터 다크 화면이었으므로, 업데이트한 사용자의 화면이 갑자기 바뀌지 않게)
    static let defaultMode: Mode = .dark

    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    private let defaults = UserDefaults.standard
    private var observation: NSKeyValueObservation?
    private static let key = "app.appearance"

    private init() {
        mode = Mode(rawValue: defaults.string(forKey: Self.key) ?? "") ?? Self.defaultMode
    }

    /// 앱 시작 시 한 번: 저장된 모양을 적용하고, 실제 모양이 바뀌면(시스템 설정 변경 포함) 터미널 기본 색을 맞춘다.
    /// 터미널 설정 파일을 쓰기 전에 불러야 첫 화면부터 맞는 색이 나온다.
    func start() {
        apply()
        guard observation == nil else { return }
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { TerminalSettings.shared.appearanceDidChange() }
        }
    }

    private func apply() {
        NSApplication.shared.appearance = mode.appearance
    }

    /// 지금 앱이 어두운 모양으로 보이는지
    static var isDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
