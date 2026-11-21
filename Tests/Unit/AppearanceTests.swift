import AppKit
import SwiftUI
import XCTest
@testable import MyTerminal

/// 앱 모양(라이트·다크)에 따른 UI 색과 터미널 기본 색
final class AppearanceTests: XCTestCase {
    /// 주어진 모양에서 색을 sRGB 로 풀어 본다
    private func resolved(_ color: Color, _ name: NSAppearance.Name) -> NSColor? {
        var result: NSColor?
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)
        }
        return result
    }

    func testThemeColorsFollowAppearance() throws {
        let light = try XCTUnwrap(resolved(Theme.windowBackground, .aqua))
        let dark = try XCTUnwrap(resolved(Theme.windowBackground, .darkAqua))
        XCTAssertGreaterThan(light.brightnessComponent, 0.8)
        XCTAssertLessThan(dark.brightnessComponent, 0.2)

        let lightText = try XCTUnwrap(resolved(Theme.textPrimary, .aqua))
        let darkText = try XCTUnwrap(resolved(Theme.textPrimary, .darkAqua))
        XCTAssertLessThan(lightText.brightnessComponent, 0.3)
        XCTAssertGreaterThan(darkText.brightnessComponent, 0.8)
    }

    func testDefaultTerminalColorsPerAppearance() {
        let dark = TerminalSettings.defaultColors(dark: true)
        let light = TerminalSettings.defaultColors(dark: false)
        XCTAssertTrue(dark.contains("background = #1b1e2b"))
        XCTAssertTrue(light.contains("background = #fbfbfd"))
        // 밝은 배경용 16색을 모두 정한다 (엔진 기본 16색은 어두운 배경용)
        XCTAssertEqual(light.filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    func testModeMapsToAppearance() {
        XCTAssertNil(AppearanceSettings.Mode.system.appearance)
        XCTAssertEqual(AppearanceSettings.Mode.light.appearance?.name, .aqua)
        XCTAssertEqual(AppearanceSettings.Mode.dark.appearance?.name, .darkAqua)
    }
}
