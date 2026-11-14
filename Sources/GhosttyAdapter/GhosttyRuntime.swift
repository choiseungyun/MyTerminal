// libghostty 프로세스 전역 상태와 런타임 콜백.
//
// 콜백 처리 방식은 Ghostty macOS 앱(macos/Sources/Ghostty/Ghostty.App.swift)을
// 참고해 단순화했다. Ghostty: Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

import AppKit
import GhosttyKit

/// libghostty 의 app 객체를 소유한다. 앱 시작 시 `GhosttyRuntime.shared` 로 한 번 만들어진다.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("[MyTerminal] ghostty_init 실패")
            return
        }

        guard let config = Self.makeConfig() else {
            NSLog("[MyTerminal] ghostty_config_new 실패")
            return
        }
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.wakeup() },
            action_cb: { _, target, action in GhosttyRuntime.handle(target: target, action: action) },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                GhosttyRuntime.readClipboard(userdata, location, state, mimes, mimesLen, list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, confirm, state, request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyRuntime.writeClipboard(userdata, location, content, len, confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            NSLog("[MyTerminal] ghostty_app_new 실패")
            return
        }
        self.app = app

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            ghostty_app_set_focus(app, true)
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            ghostty_app_set_focus(app, false)
        }
    }

    // MARK: - 설정

    /// 설정 파일을 순서대로 읽는다 (뒤가 앞을 덮어씀).
    ///   1. 앱 번들 terminal-defaults.conf  2. settings.conf (설정 화면)  3. terminal.conf (사용자 직접 편집)
    /// Ghostty 의 기본 설정 파일(~/.config/ghostty)은 읽지 않는다.
    private static func makeConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }

        var paths: [String] = []
        if let bundled = Bundle.main.path(forResource: "terminal-defaults", ofType: "conf") { paths.append(bundled) }
        if let settings = settingsConfigURL?.path { paths.append(settings) }
        if let user = userConfigURL?.path { paths.append(user) }

        for path in paths where FileManager.default.fileExists(atPath: path) {
            ghostty_config_load_file(config, path)
        }

        ghostty_config_finalize(config)
        logDiagnostics(config)
        return config
    }

    /// 설정 파일의 잘못된 줄을 로그로 남긴다.
    private static func logDiagnostics(_ config: ghostty_config_t) {
        let count = ghostty_config_diagnostics_count(config)
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(config, i)
            if let message = diag.message {
                NSLog("[MyTerminal] 설정 오류: \(String(cString: message))")
            }
        }
    }

    /// 설정 파일을 다시 읽어 열려 있는 모든 터미널에 반영한다.
    func reloadConfig() {
        guard let app, let newConfig = Self.makeConfig() else { return }
        ghostty_app_update_config(app, newConfig)
        if let old = config { ghostty_config_free(old) }
        config = newConfig
    }

    private static var supportDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MyTerminal")
    }

    /// 설정 화면이 만드는 파일: ~/Library/Application Support/MyTerminal/settings.conf
    static var settingsConfigURL: URL? { supportDirectory?.appendingPathComponent("settings.conf") }

    /// 사용자가 직접 편집하는 파일: ~/Library/Application Support/MyTerminal/terminal.conf
    static var userConfigURL: URL? { supportDirectory?.appendingPathComponent("terminal.conf") }

    // MARK: - 런타임 콜백

    /// 어느 스레드에서든 불릴 수 있으므로 메인 스레드에서 tick 한다.
    private static func wakeup() {
        DispatchQueue.main.async {
            guard let app = GhosttyRuntime.shared.app else { return }
            ghostty_app_tick(app)
        }
    }

    private static func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let view = TerminalSurfaceView.from(surface: surface) else {
            return false
        }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let ptr = action.action.set_title.title else { return false }
            let title = String(cString: ptr)
            DispatchQueue.main.async { view.onTitleChange?(title) }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let ptr = action.action.pwd.pwd else { return false }
            let pwd = String(cString: ptr)
            DispatchQueue.main.async { view.onPwdChange?(pwd) }
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            // 셸 통합(OSC 133)이 알려 주는 명령 종료. -1 이면 종료 코드를 모름.
            let code = Int(action.action.command_finished.exit_code)
            DispatchQueue.main.async { view.onCommandFinished?(code < 0 ? nil : code) }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // 메인 스레드(tick)에서 불린다. 앱이 처리하면 true → 엔진이 문구를 쓰지 않는다.
            let info = action.action.child_exited
            return view.onChildExited?(info.exit_code, info.timetime_ms) ?? false

        default:
            return false
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let view = TerminalSurfaceView.from(userdata: userdata) else { return }
        DispatchQueue.main.async { view.onClose?() }
    }

    // MARK: - 클립보드 (현재는 일반 클립보드의 text/plain 만 지원)

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?,
        _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        _ mimesLen: Int,
        _ list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let view = TerminalSurfaceView.from(userdata: userdata),
              let surface = view.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        var wantsText = false
        if let mimes {
            for i in 0..<mimesLen {
                if let ptr = mimes[i], String(cString: ptr) == "text/plain" { wantsText = true }
            }
        }

        let pasteboardText = NSPasteboard.general.string(forType: .string)
        let text = wantsText ? pasteboardText : nil
        if text == nil && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

        let available = (list && pasteboardText != nil) ? ["text/plain"] : []
        completeClipboardRequest(surface, text: text, available: available, confirmed: false, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// 여러 줄 붙여넣기처럼 확인이 필요한 경우 사용자에게 묻는다.
    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        _ state: UnsafeMutableRawPointer?,
        _ request: ghostty_clipboard_request_e
    ) {
        guard let view = TerminalSurfaceView.from(userdata: userdata),
              let surface = view.surface else { return }

        // 넘겨받은 C 메모리는 이 함수가 끝나면 무효이므로 먼저 복사한다.
        var text: String?
        if let confirm, let contents = confirm.pointee.contents {
            for i in 0..<confirm.pointee.contents_len {
                let item = contents[i]
                guard let mime = item.mime, String(cString: mime) == "text/plain",
                      let data = item.data else { continue }
                text = String(
                    decoding: UnsafeRawBufferPointer(start: data, count: item.len),
                    as: UTF8.self)
            }
        }

        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let text else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "붙여넣기 확인"
            alert.informativeText = "붙여넣을 내용에 줄바꿈 등 바로 실행될 수 있는 문자가 있습니다.\n\n"
                + String(text.prefix(500))
            alert.addButton(withTitle: "붙여넣기")
            alert.addButton(withTitle: "취소")
            if alert.runModal() == .alertFirstButtonReturn {
                completeClipboardRequest(surface, text: text, available: [], confirmed: true, state: state)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
    }

    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        text: String?,
        available: [String],
        confirmed: Bool,
        state: UnsafeMutableRawPointer?
    ) {
        var allocations: [UnsafeMutablePointer<CChar>] = []
        defer { allocations.forEach { free($0) } }

        var contents: [ghostty_clipboard_content_s] = []
        if let text, let mime = strdup("text/plain"), let data = strdup(text) {
            allocations += [mime, data]
            contents.append(ghostty_clipboard_content_s(mime: mime, data: data, len: strlen(data)))
        }

        var availablePtrs: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let ptr = strdup(mime) else { continue }
            allocations.append(ptr)
            availablePtrs.append(UnsafePointer(ptr))
        }

        contents.withUnsafeBufferPointer { contentsBuf in
            availablePtrs.withUnsafeBufferPointer { availableBuf in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuf.baseAddress,
                    contents_len: contentsBuf.count,
                    available: availableBuf.baseAddress,
                    available_len: availableBuf.count,
                    confirmed: confirmed,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        _ len: Int,
        _ confirm: Bool
    ) {
        // 확인이 필요한 쓰기(원격 프로그램의 OSC 52 등)는 아직 지원하지 않는다.
        guard location == GHOSTTY_CLIPBOARD_STANDARD, !confirm, let content else { return }

        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime) == "text/plain",
                  let data = item.data else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.declareTypes([.string], owner: nil)
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }
}
