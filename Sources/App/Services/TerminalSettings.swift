import AppKit
import Combine
import Foundation
import SwiftUI

/// 설정 화면에서 바꾸는 터미널 설정.
///
/// 값은 UserDefaults 에 저장하고, 바뀔 때마다 엔진용 설정 파일(settings.conf)을 다시 써서
/// 열려 있는 모든 터미널에 바로 반영한다.
///
/// 설정 파일을 읽는 순서 (뒤가 앞을 덮어씀):
///   1. 앱 번들 terminal-defaults.conf  — 기본값
///   2. settings.conf                  — 이 화면이 만드는 파일
///   3. terminal.conf                  — 사용자가 직접 편집하는 파일 (Ghostty 설정 형식)
final class TerminalSettings: ObservableObject {
    static let shared = TerminalSettings()

    enum CursorStyle: String, CaseIterable, Identifiable {
        case bar, block, underline
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bar: "막대"
            case .block: "블록"
            case .underline: "밑줄"
            }
        }
    }

    enum OptionAsAlt: String, CaseIterable, Identifiable {
        case off = "false", left, right, both = "true"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "사용 안 함"
            case .left: "왼쪽 Option"
            case .right: "오른쪽 Option"
            case .both: "양쪽 Option"
            }
        }
    }

    /// 빈 문자열 = 엔진 기본 글꼴 (JetBrains Mono)
    @Published var fontFamily: String
    @Published var fontSize: Double
    /// 빈 문자열 = MyTerminal 기본 색
    @Published var theme: String
    @Published var cursorStyle: CursorStyle
    @Published var cursorBlink: Bool
    @Published var optionAsAlt: OptionAsAlt
    /// true: TERM=xterm-ghostty (번들 terminfo). false: TERM=xterm-256color (기본, 호환성 우선)
    /// xterm-ghostty 는 setuid 프로그램(top 등)과 sudo 에서 terminfo 를 찾지 못한다.
    @Published var useGhosttyTerminfo: Bool

    static let defaultFontSize = 13.0
    static let fontSizeRange = 8.0...32.0

    /// MyTerminal 기본 색 (UI 색상 Theme.terminalBackground 와 맞춘다)
    static let defaultColors = ["background = #1b1e2b", "foreground = #e3e6ee"]

    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? ""
        let size = defaults.double(forKey: Keys.fontSize)
        fontSize = size > 0 ? size : Self.defaultFontSize
        theme = defaults.string(forKey: Keys.theme) ?? ""
        cursorStyle = CursorStyle(rawValue: defaults.string(forKey: Keys.cursorStyle) ?? "") ?? .bar
        cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? true
        optionAsAlt = OptionAsAlt(rawValue: defaults.string(forKey: Keys.optionAsAlt) ?? "") ?? .off
        useGhosttyTerminfo = defaults.bool(forKey: Keys.useGhosttyTerminfo)

        // 값이 바뀌면 저장하고 엔진에 반영한다. 연속 변경(크기 조절 등)은 묶어서 한 번만.
        objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.save() }
            .store(in: &cancellables)
    }

    func resetToDefaults() {
        fontFamily = ""
        fontSize = Self.defaultFontSize
        theme = ""
        cursorStyle = .bar
        cursorBlink = true
        optionAsAlt = .off
        useGhosttyTerminfo = false
    }

    /// settings.conf 내용 (Ghostty 설정 형식)
    var configText: String {
        var lines = [
            "# MyTerminal 설정 화면이 만든 파일입니다. 직접 고치지 말고 terminal.conf 를 쓰세요.",
            "font-size = \(Self.format(fontSize))",
            "cursor-style = \(cursorStyle.rawValue)",
            "cursor-style-blink = \(cursorBlink)",
            "macos-option-as-alt = \(optionAsAlt.rawValue)",
            "term = \(Self.term(useGhosttyTerminfo: useGhosttyTerminfo))",
        ]
        if !fontFamily.isEmpty { lines.append("font-family = \(Self.quote(fontFamily))") }
        // 배경·글자색을 직접 쓰면 테마보다 우선하므로, 테마를 고르면 색을 쓰지 않는다.
        if theme.isEmpty {
            lines += Self.defaultColors
        } else {
            lines.append("theme = \(Self.quote(theme))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 앱 시작 시 한 번: 저장된 설정으로 settings.conf 를 만든다 (엔진 초기화 전에 호출).
    func writeConfigFile() {
        guard let url = GhosttyRuntime.settingsConfigURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try configText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[MyTerminal] settings.conf 저장 실패: \(error)")
        }
    }

    private func save() {
        defaults.set(fontFamily, forKey: Keys.fontFamily)
        defaults.set(fontSize, forKey: Keys.fontSize)
        defaults.set(theme, forKey: Keys.theme)
        defaults.set(cursorStyle.rawValue, forKey: Keys.cursorStyle)
        defaults.set(cursorBlink, forKey: Keys.cursorBlink)
        defaults.set(optionAsAlt.rawValue, forKey: Keys.optionAsAlt)
        defaults.set(useGhosttyTerminfo, forKey: Keys.useGhosttyTerminfo)
        writeConfigFile()
        GhosttyRuntime.shared.reloadConfig()
    }

    /// 로컬 터미널의 TERM 값
    static func term(useGhosttyTerminfo: Bool) -> String {
        useGhosttyTerminfo ? "xterm-ghostty" : "xterm-256color"
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// 설정 값의 따옴표 처리 (엔진은 큰따옴표 값을 Zig 문자열로 해석한다)
    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private enum Keys {
        static let fontFamily = "terminal.fontFamily"
        static let fontSize = "terminal.fontSize"
        static let theme = "terminal.theme"
        static let cursorStyle = "terminal.cursorStyle"
        static let cursorBlink = "terminal.cursorBlink"
        static let optionAsAlt = "terminal.optionAsAlt"
        static let useGhosttyTerminfo = "terminal.useGhosttyTerminfo"
    }
}

/// 앱 번들에 들어 있는 엔진 테마 목록 (Contents/Resources/ghostty/themes)
enum ThemeCatalog {
    struct Preview {
        var background: Color
        var foreground: Color
        /// ANSI 0~7 색
        var palette: [Color]
    }

    static var themesURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes")
    }

    static let names: [String] = {
        guard let url = themesURL,
              let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return items.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    private static var cache: [String: Preview] = [:]

    /// 테마 파일에서 배경·글자색과 기본 8색을 읽는다 (목록 미리보기용).
    static func preview(_ name: String) -> Preview? {
        if let cached = cache[name] { return cached }
        guard let url = themesURL?.appendingPathComponent(name),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var bg: Color?, fg: Color?
        var palette = [Color?](repeating: nil, count: 8)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "background": bg = Color(hexString: parts[1])
            case "foreground": fg = Color(hexString: parts[1])
            case "palette":
                // palette = 1=#bb0000
                let entry = parts[1].split(separator: "=", maxSplits: 1)
                if entry.count == 2, let index = Int(entry[0]), (0..<8).contains(index) {
                    palette[index] = Color(hexString: String(entry[1]))
                }
            default: break
            }
        }
        guard let bg, let fg else { return nil }
        let preview = Preview(background: bg, foreground: fg, palette: palette.map { $0 ?? fg })
        cache[name] = preview
        return preview
    }
}

extension Color {
    /// "#rrggbb" 또는 "rrggbb"
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
