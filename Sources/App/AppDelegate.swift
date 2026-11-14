import AppKit
import OSLog
import SwiftUI

/// 종료 과정 기록 (Console.app 또는 `log show --predicate 'subsystem == "kr.weare.myterminal"'`).
/// 개수와 단계만 남기고 서버 이름 등 개인 정보는 남기지 않는다.
let lifecycleLog = Logger(subsystem: "kr.weare.myterminal", category: "lifecycle")

/// 앱 수명 주기.
///
/// - 창을 닫으면 앱을 끝낸다. (SwiftUI 단일 창 앱의 기본 동작은 창이 없어도 계속 실행되어,
///   터미널 세션이 화면 없이 뒤에서 살아 있었다)
/// - 창의 닫기 버튼(빨간 ×)과 ⌘Q 는 같은 종료 절차를 탄다: 열린 터미널이 있으면
///   **창 위에 붙는 시트**로 먼저 묻고, "종료"일 때만 창을 닫고 끝낸다. 취소하면 아무것도 바뀌지 않는다.
/// - 끝낼 때 접속 이력의 끝 시각을 남기고, 연결 재사용 ssh 연결을 정리한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkspaceStore?
    /// 메인 창 (확인 시트를 붙일 곳)
    weak var mainWindow: NSWindow?
    /// 닫힌 메인 창을 다시 여는 방법 (창 없이 종료를 취소한 드문 경우)
    var reopenMainWindow: (() -> Void)?
    /// 확인 시트가 떠 있는 동안 중복으로 묻지 않는다
    private var isConfirming = false
    /// applicationWillTerminate 까지 왔는지 (종료 감시용)
    private let terminationStarted = TerminationFlag()
    /// 종료 감시 사용 여부 (테스트에서는 끈다: 종료 판단만 부르고 실제로 끝내지 않으므로)
    var terminationWatchdogEnabled = true

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 메인 창 연결

    /// 메인 창의 닫기 버튼을 종료 절차로 바꾼다. (창이 먼저 닫히고 나서 묻지 않도록)
    func attach(to window: NSWindow) {
        mainWindow = window
        // 탭 바가 제목 표시줄 자리에 있어서, 시스템이 탭 바 전체를 "끌면 창 이동" 영역으로 본다.
        // 그러면 탭을 끌 때 창도 같이 움직이므로 자동 이동을 끄고, 탭 바의 빈 곳(WindowDragArea)만 직접 창을 옮긴다.
        window.isMovable = false
        guard let close = window.standardWindowButton(.closeButton) else { return }
        close.target = self
        close.action = #selector(closeButtonClicked(_:))
    }

    @objc func closeButtonClicked(_ sender: Any?) {
        lifecycleLog.info("닫기 버튼 → 종료 요청")
        NSApp.terminate(sender)
    }

    // MARK: - 종료

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, let message = Self.confirmationMessage(for: store) else {
            lifecycleLog.info("종료 판단: 열린 접속 없음 → 바로 종료 (store=\(self.store != nil, privacy: .public))")
            prepareToTerminate()
            return .terminateNow
        }
        if isConfirming {
            lifecycleLog.info("종료 판단: 확인 시트가 이미 떠 있음 → 이번 요청 취소")
            return .terminateCancel
        }
        lifecycleLog.info("종료 판단: 터미널 \(store.tabs.flatMap(\.panes).count, privacy: .public)개, SFTP \(store.sftpRemote != nil, privacy: .public) → 확인")

        let alert = Self.makeAlert(message)

        // 창이 보이면 그 창 위에 시트로 묻고, 답이 오면 종료 여부를 알려 준다.
        if let window = mainWindow, window.isVisible {
            isConfirming = true
            alert.beginSheetModal(for: window) { [weak self] response in
                lifecycleLog.info("확인 시트 응답: \(response == .alertFirstButtonReturn ? "종료" : "취소", privacy: .public)")
                self?.isConfirming = false
                if response == .alertFirstButtonReturn { self?.prepareToTerminate() }
                NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
            }
            return .terminateLater
        }

        // 창이 없는 드문 경우: 따로 묻고, 취소하면 창을 다시 연다 (세션은 그대로).
        if alert.runModal() == .alertFirstButtonReturn {
            prepareToTerminate()
            return .terminateNow
        }
        reopenMainWindow?()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard terminationStarted.begin() else { return }
        lifecycleLog.info("종료 시작")
        Self.cleanUp(history: store?.history)
    }

    /// 끝내기 전 정리: 열린 접속 이력의 끝 시각, 연결 재사용 ssh 연결
    private static func cleanUp(history: HistoryStore?) {
        history?.endAllOpenForExit()
        let started = Date()
        let sockets = SSHMultiplex.sockets().count
        SSHMultiplex.closeAll()
        lifecycleLog.info("연결 재사용 정리: \(sockets, privacy: .public)개, \(Date().timeIntervalSince(started), privacy: .public)초 → 종료")
    }

    /// 종료 직전 준비: 끌어 놓기 약속을 풀고, 감시를 건다.
    private func prepareToTerminate() {
        Self.releaseDragPromises()
        armTerminationWatchdog()
    }

    /// 끌어 놓기 칠판(drag pasteboard)을 비운다.
    ///
    /// 서버 파일을 끌면 "놓는 곳에서 요청하면 그때 내려받아 넘겨줄" 약속이 칠판에 남는다.
    /// macOS 는 앱을 끝낼 때 다른 앱이 계속 쓸 수 있도록 이 약속을 메인 스레드에서 채우라고 요청하는데,
    /// 우리 앱은 내려받기를 메인 스레드에서 이어 가므로 서로 기다리며 종료가 멈췄다 (실험으로 확인).
    /// 끝내기 전에 칠판을 비우면 요청이 오지 않는다.
    static func releaseDragPromises(_ pasteboard: NSPasteboard = NSPasteboard(name: .drag)) {
        guard !(pasteboard.pasteboardItems ?? []).isEmpty else { return }
        pasteboard.clearContents()
        lifecycleLog.info("끌어 놓기 칠판 비움 (종료 전)")
    }

    /// 종료 감시: 종료하기로 정했는데 시스템이 종료를 진행하지 않으면(끝나지 않은 끌어 놓기 파일 약속 등)
    /// 몇 초 뒤 정리하고 직접 끝낸다. 메인 스레드가 막혀 있어도 동작하도록 백그라운드에서 센다.
    /// 정상 종료는 판단 뒤 수 밀리초 안에 진행되므로 1초면 충분하다
    static let terminationGrace: TimeInterval = 1

    private func armTerminationWatchdog() {
        guard terminationWatchdogEnabled else { return }
        let flag = terminationStarted
        let history = store?.history
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.terminationGrace) {
            guard flag.begin() else { return }
            lifecycleLog.error("시스템이 \(Self.terminationGrace, privacy: .public)초 안에 종료를 진행하지 않아 직접 끝냅니다")
            Self.logMainThreadState()
            Self.captureSample()
            Self.cleanUp(history: history)
            UserDefaults.standard.synchronize()
            exit(0)
        }
    }

    static func makeAlert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "MyTerminal 을 종료할까요?"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        return alert
    }

    /// 종료 전에 물을 문장. 열린 터미널이 없으면 nil (바로 종료)
    static func confirmationMessage(for store: WorkspaceStore) -> String? {
        let panes = store.tabs.flatMap(\.panes)
        let ssh = panes.filter { $0.target != nil }.count
        let sftp = store.sftpRemote != nil ? 1 : 0
        guard !panes.isEmpty || sftp > 0 else { return nil }

        var parts: [String] = []
        if !panes.isEmpty { parts.append("터미널 \(panes.count)개" + (ssh > 0 ? " (SSH 접속 \(ssh)개)" : "")) }
        if sftp > 0 { parts.append("SFTP 접속 1개") }
        return parts.joined(separator: ", ") + " 가 열려 있습니다. 종료하면 모두 닫히고 접속이 끊어집니다."
    }
}

extension AppDelegate {
    /// 종료가 멈췄을 때 원인을 찾기 위한 기록: 메인 스레드가 응답하는지, 어떤 실행 모드에서 기다리는지, 호출 경로.
    /// 함수 이름만 남는다 (화면 내용·서버 이름 등은 남지 않는다).
    static func logMainThreadState() {
        let semaphore = DispatchSemaphore(value: 0)
        var report = "메인 스레드 응답 없음 (막혀 있음)"
        DispatchQueue.main.async {
            let mode = RunLoop.current.currentMode?.rawValue ?? "없음"
            let sheets = NSApp.windows.filter { $0.attachedSheet != nil }.count
            let visible = NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) }
            let stack = Thread.callStackSymbols.prefix(40).map { line in
                // "12  AppKit  0x...  -[NSApplication run] + 396" → 모듈과 함수 이름만
                line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().filter { !$0.hasPrefix("0x") }.joined(separator: " ")
            }.joined(separator: "\n")
            report = "메인 스레드 응답함, 실행 모드=\(mode), 모달 창=\(NSApp.modalWindow != nil), 시트=\(sheets), 보이는 창=\(visible)\n\(stack)"
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 0.5)
        lifecycleLog.error("종료 지연 진단: \(report, privacy: .public)")
    }
}

extension AppDelegate {
    /// 종료가 멈췄을 때 macOS `sample` 로 모든 스레드의 호출 경로를 파일로 남긴다 (이 Mac 에만 저장).
    /// ~/Library/Logs/MyTerminal/termination-hang-<시각>.txt
    static func captureSample() {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/MyTerminal") else { return }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let file = logs.appendingPathComponent("termination-hang-\(stamp).txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "1", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        lifecycleLog.error("종료 지연 호출 경로 저장: \(file.lastPathComponent, privacy: .public)")
    }
}

/// 종료 정리를 한 번만 하도록 (메인 스레드·감시 스레드가 함께 쓴다)
final class TerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    /// 처음 부를 때만 true
    func begin() -> Bool {
        lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
    }
}

/// 메인 창을 AppDelegate 에 연결한다 (닫기 버튼 연결, 다시 열기 동작)
struct MainWindowConnector: NSViewRepresentable {
    let appDelegate: AppDelegate
    let reopen: () -> Void

    final class ProbeView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = { [appDelegate, reopen] window in
            appDelegate.attach(to: window)
            appDelegate.reopenMainWindow = reopen
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}
}
