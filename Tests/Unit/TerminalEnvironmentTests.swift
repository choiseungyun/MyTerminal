import AppKit
import XCTest
@testable import MyTerminal

/// 실제 터미널 화면을 만들어 셸에 전달되는 환경변수를 확인한다.
@MainActor
final class TerminalEnvironmentTests: XCTestCase {
    private var output: URL!

    override func setUp() {
        super.setUp()
        output = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterm-env-\(UUID().uuidString).txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: output)
        super.tearDown()
    }

    /// 화면에서 `env` 를 실행해 결과를 키-값으로 돌려준다.
    private func environment(of options: TerminalSurfaceView.Options) -> [String: String] {
        var options = options
        options.command = "/usr/bin/env > \(output.path)"
        let view = TerminalSurfaceView(options: options)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let text = try? String(contentsOf: output, encoding: .utf8), text.contains("PATH=") { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        withExtendedLifetime(view) {}

        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { env[String(parts[0])] = String(parts[1]) }
        }
        return env
    }

    /// 설정에 따른 로컬 터미널의 TERM 값
    private var expectedTerm: String {
        TerminalSettings.term(useGhosttyTerminfo: TerminalSettings.shared.useGhosttyTerminfo)
    }

    func testLocalTerminalUsesBundledTerminfo() throws {
        let env = environment(of: .init())
        XCTAssertFalse(env.isEmpty, "env 결과를 받지 못함")
        XCTAssertEqual(env["TERM"], expectedTerm)
        XCTAssertEqual(env["COLORTERM"], "truecolor")

        let terminfo = try XCTUnwrap(env["TERMINFO"], "TERMINFO 가 설정되지 않음")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: terminfo + "/78/xterm-ghostty"),
            "번들에 terminfo 가 없음: \(terminfo)")
    }

    func testEnvironmentOverrideWinsOverTerm() {
        var options = TerminalSurfaceView.Options()
        options.environment = ["TERM": "xterm-256color", "MYTERM_SESSION_ID": "test-session"]
        let env = environment(of: options)
        XCTAssertEqual(env["TERM"], "xterm-256color", "SSH 화면용 TERM 덮어쓰기가 적용되지 않음")
        XCTAssertEqual(env["MYTERM_SESSION_ID"], "test-session")
    }
}

extension TerminalEnvironmentTests {
    /// 사용자 로그인 셸(설정 파일 포함) 안에서 ncurses 프로그램이 xterm-ghostty 를 읽을 수 있어야 한다.
    /// (환경변수만 확인하면 놓치는 문제: top 의 "Error opening terminal: xterm-ghostty")
    func testLoginShellProgramsCanOpenTerminfo() throws {
        let text = runInLoginShell("echo TERM=$TERM; echo TERMINFO=$TERMINFO; tput colors; echo DONE")
        XCTAssertTrue(text.contains("DONE"), "셸 실행 결과를 받지 못함:\n\(text)")
        XCTAssertTrue(text.contains("TERM=\(expectedTerm)"), text)
        XCTAssertFalse(text.contains("unknown terminal"), "terminfo 를 찾지 못함:\n\(text)")
        XCTAssertTrue(text.contains("\n256\n"), "tput colors 결과가 256 이 아님:\n\(text)")
    }

    /// 기본 TERM 은 TERMINFO 없이(시스템 terminfo 만으로)도 열려야 한다.
    /// setuid 프로그램(/usr/bin/top)과 sudo 는 TERMINFO 를 무시하기 때문이다.
    /// (회귀: top 에서 "Error opening terminal: xterm-ghostty")
    func testDefaultTermWorksWithoutBundledTerminfo() throws {
        try XCTSkipIf(TerminalSettings.shared.useGhosttyTerminfo, "Ghostty 전용 terminfo 설정이 켜져 있음")
        let text = runInLoginShell("echo TERM=$TERM; env -u TERMINFO tput colors; echo DONE")
        XCTAssertTrue(text.contains("DONE"), "셸 실행 결과를 받지 못함:\n\(text)")
        XCTAssertFalse(text.contains("unknown terminal"), "시스템 terminfo 에 없는 TERM:\n\(text)")
        XCTAssertTrue(text.contains("\n256\n"), "tput colors 결과가 256 이 아님:\n\(text)")
    }

    /// 사용자 로그인 셸(설정 파일 포함)에서 스크립트를 실행하고 출력을 돌려준다.
    private func runInLoginShell(_ script: String) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var options = TerminalSurfaceView.Options()
        options.command = "\(shell) -lic '\(script)' > \(output.path) 2>&1"
        let view = TerminalSurfaceView(options: options)

        let deadline = Date().addingTimeInterval(15)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            if text.contains("DONE") { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        withExtendedLifetime(view) {}
        return text
    }

    /// 설정 화면에서 값을 바꾸면 열린 화면이 있는 상태로 설정을 다시 읽는다. 이때 멈추거나 죽지 않아야 한다.
    func testReloadConfigWithOpenSurface() {
        let view = TerminalSurfaceView(options: .init())
        XCTAssertNotNil(view.surface)
        GhosttyRuntime.shared.reloadConfig()
        GhosttyRuntime.shared.reloadConfig()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(GhosttyRuntime.shared.app)
        withExtendedLifetime(view) {}
    }
}

final class ThemeCatalogTests: XCTestCase {
    func testBundledThemesAreListed() {
        XCTAssertGreaterThan(ThemeCatalog.names.count, 100, "번들 테마 목록이 비어 있음")
        XCTAssertTrue(ThemeCatalog.names.contains("Builtin Dark"))
    }

    func testThemePreviewParsesColors() throws {
        let preview = try XCTUnwrap(ThemeCatalog.preview("Builtin Dark"))
        XCTAssertEqual(preview.palette.count, 8)
    }
}
