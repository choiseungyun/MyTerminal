import Darwin
import Foundation
import Security

/// 저장된 비밀번호를 ssh 에 자동으로 넣어 주는 SSH_ASKPASS 서버.
///
/// 동작:
///   1. 비밀번호 호스트의 ssh 화면을 열 때 `environment(for:)` 가 일회용 토큰을 발급하고
///      SSH_ASKPASS(도우미 스크립트), SSH_ASKPASS_REQUIRE=force 환경변수를 만든다.
///   2. ssh 가 비밀번호를 물으면 스크립트가 토큰과 질문을 이 서버(Unix 소켓)로 보낸다.
///   3. 서버는 같은 사용자인지, 토큰이 유효한지, 질문에 그 호스트 이름이 있는지 확인한 뒤
///      Keychain 의 비밀번호를 돌려준다. 아니면 빈 응답 → 스크립트가 터미널에서 직접 묻는다.
///
/// 보안: 소켓과 스크립트는 사용자 전용 임시 폴더(0700)에 만든다. 비밀번호는 디스크에 쓰지 않는다.
final class AskpassServer {
    static let shared = AskpassServer()

    struct Registration {
        let hostID: UUID
        /// 질문에 이 이름 중 하나가 있어야 비밀번호를 준다 (점프 호스트 등 다른 서버 보호)
        let names: [String]
    }

    let directory: URL
    var socketPath: String { directory.appendingPathComponent("askpass.sock").path }
    var scriptPath: String { directory.appendingPathComponent("askpass.sh").path }

    private let passwordProvider: (UUID) -> String?
    private var registrations: [String: Registration] = [:]
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "dev.myterminal.askpass")

    init(
        directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MyTerminal"),
        passwordProvider: @escaping (UUID) -> String? = { Keychain.password(hostID: $0) }
    ) {
        self.directory = directory
        self.passwordProvider = passwordProvider
    }

    deinit { stop() }

    // MARK: - 화면에서 쓰는 API

    /// ssh 화면에 넣을 환경변수와 토큰. 비밀번호 자동 입력을 쓰지 않거나 서버를 열 수 없으면 nil.
    func environment(for launch: SSHLaunch) -> (environment: [String: String], token: String)? {
        guard launch.usesSavedPassword, let hostID = launch.hostID, startIfNeeded() else { return nil }
        let token = register(Registration(hostID: hostID, names: launch.hostNames))
        return ([
            "SSH_ASKPASS": scriptPath,
            "SSH_ASKPASS_REQUIRE": "force",
            "MYTERM_ASKPASS_TOKEN": token,
            "MYTERM_ASKPASS_SOCKET": socketPath,
            "MYTERM_ASKPASS_DIR": directory.path,
        ], token)
    }

    func register(_ registration: Registration) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock { registrations[token] = registration }
        return token
    }

    func unregister(_ token: String) {
        lock.withLock { _ = registrations.removeValue(forKey: token) }
    }

    // MARK: - 서버

    /// 폴더·스크립트·소켓을 준비하고 연결을 받기 시작한다. 이미 열려 있으면 바로 true.
    @discardableResult
    func startIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if listenFD >= 0 { return true }

        do {
            try prepareDirectory()
            try Self.script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            chmod(scriptPath, 0o700)
        } catch {
            NSLog("[MyTerminal] askpass 준비 실패: \(error)")
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            NSLog("[MyTerminal] askpass 소켓 경로가 너무 김: \(socketPath)")
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        unlink(socketPath)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 16) == 0 else {
            NSLog("[MyTerminal] askpass 소켓 열기 실패: errno \(errno)")
            close(fd)
            return false
        }

        listenFD = fd
        queue.async { [weak self] in self?.acceptLoop(fd) }
        return true
    }

    func stop() {
        lock.withLock {
            guard listenFD >= 0 else { return }
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    private func prepareDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        // 지난 실행이 남긴 재시도 표시 파일 정리
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix("tried-") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // 소켓이 닫혔다 (stop)
            }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }

        // 같은 사용자의 프로세스만 받는다.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // 요청: "<토큰>\n<ssh 의 질문>\n"
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while data.count < 4096, data.filter({ $0 == 0x0A }).count < 2 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard let tokenLine = lines.first else { return }
        let token = String(tokenLine).trimmingCharacters(in: .whitespaces)
        let prompt = lines.count > 1 ? String(lines[1]) : ""

        guard let password = password(token: token, prompt: prompt) else { return }
        let reply = Array((password + "\n").utf8)
        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    /// 토큰과 질문을 확인하고 비밀번호를 돌려준다.
    func password(token: String, prompt: String) -> String? {
        guard let registration = lock.withLock({ registrations[token] }) else { return nil }
        guard Self.prompt(prompt, matches: registration.names) else { return nil }
        return passwordProvider(registration.hostID)
    }

    /// "deploy@web-01's password:" 처럼 대상이 드러난 질문은 이름이 맞을 때만 허용한다.
    /// "Password:" 처럼 대상이 없는 질문(keyboard-interactive)은 허용한다.
    static func prompt(_ prompt: String, matches names: [String]) -> Bool {
        let lower = prompt.lowercased()
        guard lower.contains("password") else { return false }
        guard lower.contains("@") else { return true }
        return names.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
    }

    // MARK: - 도우미 스크립트

    /// ssh 가 SSH_ASKPASS 로 실행하는 스크립트. $1 은 ssh 의 질문이다.
    static let script = #"""
    #!/bin/sh
    # MyTerminal SSH_ASKPASS 도우미 (앱이 자동으로 만든 파일)
    # 비밀번호 질문이면 앱에 저장된 비밀번호를 요청하고, 그 밖의 질문은 터미널에서 직접 묻는다.
    prompt="$1"

    ask_tty() {
        printf '%s' "$prompt" > /dev/tty
        if [ "$1" = secret ]; then stty -echo < /dev/tty; fi
        IFS= read -r answer < /dev/tty
        if [ "$1" = secret ]; then stty echo < /dev/tty; printf '\n' > /dev/tty; fi
        printf '%s\n' "$answer"
    }

    case "$prompt" in
        *[Pp]assword*)
            # 같은 ssh 에서 두 번째로 묻는다면 저장된 비밀번호가 틀린 것: 터미널에서 묻는다.
            marker="$MYTERM_ASKPASS_DIR/tried-$PPID"
            if [ -n "$MYTERM_ASKPASS_TOKEN" ] && [ ! -e "$marker" ]; then
                : > "$marker"
                pw=$(printf '%s\n%s\n' "$MYTERM_ASKPASS_TOKEN" "$prompt" | /usr/bin/nc -U "$MYTERM_ASKPASS_SOCKET" 2>/dev/null)
                if [ -n "$pw" ]; then
                    printf '%s\n' "$pw"
                    exit 0
                fi
            fi
            ask_tty secret
            ;;
        *[Pp]assphrase*|*PIN*|*[Cc]ode*|*[Tt]oken*|*OTP*)
            ask_tty secret
            ;;
        *)
            ask_tty plain
            ;;
    esac
    """#
}
