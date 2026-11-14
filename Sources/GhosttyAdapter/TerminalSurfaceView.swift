// 터미널 화면 하나(libghostty surface)를 담는 NSView.
//
// 키 입력·한글 IME(NSTextInputClient) 처리는 Ghostty macOS 앱
// (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift)의 방식을 따라 단순화했다.
// Ghostty: Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

import AppKit
import GhosttyKit

final class TerminalSurfaceView: NSView, NSTextInputClient {
    struct Options {
        /// 실행할 명령. nil 이면 사용자 로그인 셸.
        var command: String?
        var workingDirectory: String?
        var environment: [String: String] = [:]
        /// 명령이 끝나도 화면을 닫지 않는다 (ssh 접속 실패 메시지를 보이기 위해).
        var waitAfterCommand = false
    }

    private(set) var surface: ghostty_surface_t?

    var onTitleChange: ((String) -> Void)?
    var onPwdChange: ((String) -> Void)?
    var onClose: (() -> Void)?
    /// 이 화면이 키 입력 포커스를 받았을 때 (분할 화면 중 활성 화면 추적용)
    var onFocus: (() -> Void)?
    /// 셸·명령이 끝났을 때 (종료 코드, 실행 시간 ms). true 를 돌려주면 엔진의 "Process exited…" 문구를 쓰지 않는다.
    var onChildExited: ((_ exitCode: UInt32, _ runtimeMs: UInt64) -> Bool)?
    /// 셸 통합이 알려 주는 명령 하나의 종료 (종료 코드, 알 수 없으면 nil)
    var onCommandFinished: ((_ exitCode: Int?) -> Void)?
    /// 지금 이 화면을 담아야 하는 SwiftUI 컨테이너 (가장 최근에 만들어진 것).
    /// 분할 구조가 바뀌면 SwiftUI 가 새 컨테이너를 만든 뒤에도 사라질 옛 컨테이너를 한 번 더 갱신하는데,
    /// 그때 옛 컨테이너가 화면을 도로 가져가지 않도록 주인을 기록해 둔다.
    weak var host: NSView?

    /// IME 조합 중인 글자 (예: 한글 조합 중 "하")
    private var markedText = NSMutableAttributedString()
    /// keyDown 처리 중에 IME 가 확정한 글자를 모은다. nil 이면 keyDown 밖.
    private var keyTextAccumulator: [String]?
    private var trackingArea: NSTrackingArea?

    init(options: Options) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        createSurface(options)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: - 화면 글자 읽기·입력 (AI 기능)

    /// 입력줄에 글자를 넣는다. 붙여넣기처럼 처리되며 Enter 는 보내지 않는다.
    func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { base in
                base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    ghostty_surface_text(surface, $0, UInt(buffer.count))
                }
            }
        }
    }

    /// 마우스로 선택한 글자 (없으면 nil)
    func selectedText() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return nil }
        let value = String(cString: ptr)
        return value.isEmpty ? nil : value
    }

    /// 지금 화면에 보이는 글자 (마지막 `lastLines` 줄, 끝의 빈 줄 제외)
    func visibleText(lastLines: Int = 80) -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        var lines = String(cString: ptr).components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(lastLines).joined(separator: "\n")
    }

    static func from(userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func from(surface: ghostty_surface_t) -> TerminalSurfaceView? {
        from(userdata: ghostty_surface_userdata(surface))
    }

    // MARK: - surface 생성

    private func createSurface(_ options: Options) {
        guard let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.wait_after_command = options.waitAfterCommand
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // C 문자열은 ghostty_surface_new 가 복사하므로 호출 뒤에 해제한다.
        var allocations: [UnsafeMutablePointer<CChar>] = []
        defer { allocations.forEach { free($0) } }
        func cString(_ s: String?) -> UnsafePointer<CChar>? {
            guard let s, let p = strdup(s) else { return nil }
            allocations.append(p)
            return UnsafePointer(p)
        }

        cfg.command = cString(options.command)
        cfg.working_directory = cString(options.workingDirectory)

        var env = options.environment.map { key, value in
            ghostty_env_var_s(key: cString(key), value: cString(value))
        }
        surface = env.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(app, &cfg)
        }

        if surface == nil { NSLog("[MyTerminal] ghostty_surface_new 실패") }
    }

    // MARK: - 크기, 배율, 포커스

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface {
            ghostty_surface_set_focus(surface, true)
            onFocus?()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        if let surface {
            let scale = convertToBacking(NSSize(width: 1, height: 1))
            ghostty_surface_set_content_scale(surface, scale.width, scale.height)
        }
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        viewDidChangeBackingProperties()
    }

    private func updateSurfaceSize() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let size = convertToBacking(frame.size)
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    // MARK: - 키보드

    override func keyDown(with event: NSEvent) {
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // option-as-alt 설정에 따라 글자 생성에 쓸 수정 키를 엔진에 물어 바꾼다.
        // (예: option 을 Alt 로 쓰면 option+b 가 "∫" 대신 b 로 해석되어 ESC b 가 된다)
        let translationEvent = translatedEvent(event)

        // keyDown 동안 IME 가 확정한 글자를 모은다 (한글 등 조합형 입력).
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: markedTextBefore)

        let composing = markedText.length > 0 || markedTextBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                if markedTextBefore {
                    // 조합 중이던 글자가 확정된 것: 키 자체는 다시 보내지 않는다.
                    _ = sendCommittedText(action, text: text)
                } else {
                    _ = sendKey(action, event: event, translationMods: translationEvent.modifierFlags, text: text)
                }
            }
            return
        }

        if Self.isComposingControl(event.characters, composing: composing) { return }
        _ = sendKey(
            action,
            event: event,
            translationMods: translationEvent.modifierFlags,
            text: Self.terminalCharacters(translationEvent),
            composing: composing)
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// 수정 키만 눌렀다 뗀 입력 (일부 프로그램이 shift·ctrl 단독 입력을 쓴다)
    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        // IME 조합 중에는 수정 키를 보내지 않는다.
        if hasMarkedText() { return }

        // 해당 수정 키가 눌린 상태면 press, 아니면 release
        let pressed = Self.mods(event.modifierFlags).rawValue & mod != 0
        _ = sendKey(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// 엔진이 알려 준 수정 키로 글자를 다시 해석한 이벤트. 수정 키가 같으면 원래 이벤트를 그대로 쓴다.
    /// (같은 객체를 써야 한글 입력기가 정상 동작한다 — Ghostty 주석 참고)
    private func translatedEvent(_ event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let translated = Self.modifierFlags(
            ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))

        var flags = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { flags.insert(flag) } else { flags.remove(flag) }
        }
        if flags == event.modifierFlags { return event }

        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode) ?? event
    }

    /// 처리하지 않은 편집 명령에서 경고음이 나지 않게 한다.
    override func doCommand(by selector: Selector) {}

    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        // control, command 는 글자 생성에 쓰이지 않는다고 본다 (Ghostty 와 같은 가정).
        // option-as-alt 이면 option 도 글자 생성에 쓰이지 않으므로 translationMods 기준으로 계산한다.
        key.consumed_mods = Self.mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.composing = composing
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?
                .unicodeScalars.first?.value ?? 0
        }

        guard let text, !text.isEmpty else { return ghostty_surface_key(surface, key) }
        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
    }

    private func sendCommittedText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// 단일 제어 문자는 Ghostty 가 직접 인코딩하므로 control 을 뺀 글자를 보낸다.
    /// 기능 키(PUA 영역)는 글자를 보내지 않는다.
    private static func terminalCharacters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return chars
    }

    /// IME 조합 중에 들어온 제어 문자는 IME 몫이므로 터미널로 보내지 않는다.
    private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // 오른쪽 수정 키 구분 (엔진 설정 macos-option-as-alt = right 등에 쓰인다)
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func modifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    // MARK: - 편집 메뉴 (⌘C, ⌘V, ⌘A)

    /// 화면 지우기 (⌘K 를 AI 명령 추천에 쓰므로 메뉴로 제공)
    func clearScreen() { performBinding("clear_screen") }

    @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }
    override func selectAll(_ sender: Any?) { performBinding("select_all") }

    private func performBinding(_ action: String) {
        guard let surface else { return }
        action.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    // MARK: - 마우스

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }
    override func mouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    override func rightMouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    override func rightMouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            // 트랙패드 스크롤을 Ghostty 앱과 비슷한 속도로 맞춘다.
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, precise ? 1 : 0)
    }

    private func sendMouseButton(
        _ state: ghostty_input_mouse_state_e,
        _ button: ghostty_input_mouse_button_e,
        _ event: NSEvent
    ) {
        guard let surface else { return }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // Ghostty 좌표는 왼쪽 위가 원점이다.
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.mods(event.modifierFlags))
    }

    // MARK: - NSTextInputClient (IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        if !chars.isEmpty { _ = sendCommittedText(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // keyDown 밖(예: 입력기 전환)에서 바뀐 조합은 바로 반영한다.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// IME 후보 창을 커서 위치에 띄우기 위한 좌표.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let viewRect = NSRect(x: x, y: frame.height - y, width: 0, height: height)
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }
}
