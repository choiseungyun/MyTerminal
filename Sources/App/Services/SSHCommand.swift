import Darwin
import Foundation

/// 터미널 화면·SFTP 에서 쓰는 ssh 접속 정보
struct SSHLaunch: Hashable {
    /// 탭·카드 제목
    var title: String
    /// 사용자 이름 (상태 줄 표시용)
    var user: String?
    /// ssh 에 넘길 접속 인자 ("ssh" 와 앱의 연결 옵션 제외). 예: ["-p", "2222", "deploy@web-01"]
    var arguments: [String]
    /// 저장된 호스트에서 연 경우 그 id (최근 접속 기록, 비밀번호 자동 입력)
    var hostID: UUID?
    /// 비밀번호 자동 입력을 쓸지
    var usesSavedPassword = false
    /// 비밀번호 질문이 이 호스트를 가리키는지 확인할 이름들 (주소, ssh config 별칭)
    var hostNames: [String] = []
    /// 접속한 뒤 서버에서 실행할 명령 (터미널에서만 쓰고 SFTP 에는 쓰지 않는다)
    var remoteCommand: String?

    /// 터미널에서 실행할 명령줄 (연결 재사용 옵션 포함, 셸 따옴표 처리)
    var commandLine: String {
        SSHCommand.commandLine(SSHMultiplex.connectionOptions + terminalArguments)
    }

    /// 사람에게 보여 주거나 복사할 명령 (앱 내부 옵션 제외)
    var displayCommand: String {
        SSHCommand.commandLine(terminalArguments)
    }

    /// 터미널용 인자: 실행할 명령이 있으면 -t (원격 명령에도 터미널 할당) + 명령을 붙인다.
    var terminalArguments: [String] {
        guard let command = remoteCommand?.trimmingCharacters(in: .whitespaces), !command.isEmpty else { return arguments }
        return ["-t"] + arguments + [command]
    }
}

/// ssh 의 실제 종료 코드를 남긴다.
///
/// 엔진이 알려 주는 종료 코드는 macOS 에서 /usr/bin/login 래퍼를 거쳐 항상 0 이라 쓸 수 없다
/// (Ghostty 주석과 실험으로 확인). 그래서 ssh 를 작은 셸로 감싸 실제 종료 코드를 화면별 파일에 쓰고,
/// 화면이 끝났을 때 그 파일을 읽어 정상 종료(0)면 화면을 닫고, 아니면 메시지를 남긴다.
enum ExitStatus {
    static let environmentKey = "MYTERM_EXIT_FILE"

    /// "ssh …" 명령줄을 감싼다: 실행 → 종료 코드를 $MYTERM_EXIT_FILE 에 기록 → 같은 코드로 끝냄
    static func wrap(_ commandLine: String) -> String {
        let script = #""$@"; s=$?; [ -n "$MYTERM_EXIT_FILE" ] && printf '%s' "$s" > "$MYTERM_EXIT_FILE"; exit "$s""#
        return "/bin/sh -c " + SSHCommand.shellQuote(script) + " myterminal " + commandLine
    }

    /// 화면별 종료 코드 파일 (사용자 전용 임시 폴더)
    static func fileURL(for paneID: UUID) -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MyTerminal/exit", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent(paneID.uuidString)
    }

    /// 기록된 종료 코드. 파일이 없으면(신호로 끝남 등) nil
    static func read(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// ssh 연결 재사용 (ControlMaster). 터미널에서 인증한 연결을 SFTP·분할 화면이 그대로 쓴다.
/// 결정 배경: docs/decisions/0004-sftp-over-openssh.md
enum SSHMultiplex {
    /// 소켓 폴더. Unix 소켓 경로 제한(104바이트, ssh 가 임시 접미사 17자를 붙임) 때문에 짧은 경로를 쓴다.
    static var directory: String { "/tmp/myterm-\(getuid())" }

    static let persistSeconds = 600

    /// 폴더를 쓸 수 있으면 연결 재사용 옵션, 아니면 빈 배열 (재사용 없이 접속)
    static var connectionOptions: [String] {
        guard prepare() else { return [] }
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(directory)/%C",
            "-o", "ControlPersist=\(persistSeconds)",
        ]
    }

    /// 앱을 끝낼 때: 이 앱이 만든 연결 재사용 ssh 연결을 모두 끝낸다 (뒤에 남지 않게).
    /// 폴더 안의 소켓마다 `ssh -O exit` 를 보낸다.
    static func closeAll(timeout: TimeInterval = 2) {
        for socket in sockets() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-O", "exit", "-o", "ControlPath=\(socket)", "myterminal-mux"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
        }
    }

    /// 폴더 안의 소켓 파일 경로
    static func sockets() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.map { directory + "/" + $0 }.filter { path in
            var info = Darwin.stat()
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
        }
    }

    /// 폴더를 만들고 안전한지 확인한다. /tmp 는 공용이므로 남이 만든 폴더나 링크면 쓰지 않는다.
    @discardableResult
    static func prepare() -> Bool {
        let path = directory
        if mkdir(path, 0o700) != 0 && errno != EEXIST { return false }
        var info = Darwin.stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else {
            NSLog("[MyTerminal] 연결 재사용 폴더를 쓸 수 없음: \(path)")
            return false
        }
        if info.st_mode & 0o077 != 0 { chmod(path, 0o700) }
        return true
    }
}

enum SSHCommand {
    /// 경유 호스트를 id 로 찾는 방법 (기본: 저장된 호스트 목록)
    typealias HostResolver = (UUID) -> SSHHost?
    static let savedHosts: HostResolver = { HostStore.shared.host($0) }

    /// 저장된 호스트의 ssh 인자. ssh config 에서 가져온 호스트는 별칭만 넘겨 ssh 설정을 그대로 따른다.
    static func arguments(for host: SSHHost, resolve: HostResolver = savedHosts) -> [String] {
        arguments(for: host, resolve: resolve, depth: 0)
    }

    private static func arguments(for host: SSHHost, resolve: HostResolver, depth: Int) -> [String] {
        var args: [String] = []
        if let alias = host.sshConfigAlias {
            args.append(alias)
            return args
        }

        if let port = host.port, port != 22 { args += ["-p", String(port)] }
        if let key = nonEmpty(host.identityFile) {
            args += ["-i", (key as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        // 경유: 저장된 호스트를 골랐으면 그 호스트의 설정(키·포트·사용자·그 호스트의 경유)으로 터널을 만든다.
        // (-J 로 넘기면 경유 서버에 -i 키가 적용되지 않는다)
        if let jumpID = host.jumpHostID, depth < 5, let jump = resolve(jumpID), jump.id != host.id {
            args += ["-o", "ProxyCommand=" + proxyCommand(through: jump, resolve: resolve, depth: depth + 1)]
        } else if let jump = nonEmpty(host.jumpHost) {
            args += ["-J", jump]
        }

        if let user = nonEmpty(host.user) {
            args.append("\(user)@\(host.hostname)")
        } else {
            args.append(host.hostname)
        }
        return args
    }

    /// 경유 호스트로 대상 서버(%h:%p)까지 터널을 여는 ssh 명령 (ProxyCommand 값)
    static func proxyCommand(through jump: SSHHost, resolve: HostResolver = savedHosts, depth: Int = 1) -> String {
        var jumpArgs = arguments(for: jump, resolve: resolve, depth: depth)
        // -W 는 목적지보다 앞에 둔다
        jumpArgs.insert(contentsOf: ["-W", "%h:%p"], at: max(0, jumpArgs.count - 1))
        return commandLine(jumpArgs)
    }

    static func launch(for host: SSHHost, resolve: HostResolver = savedHosts) -> SSHLaunch {
        SSHLaunch(
            title: host.displayName,
            user: host.user,
            arguments: arguments(for: host, resolve: resolve),
            hostID: host.id,
            usesSavedPassword: host.authMethod == .password,
            hostNames: [host.hostname, host.sshConfigAlias].compactMap { $0 }.filter { !$0.isEmpty },
            remoteCommand: host.remoteCommand)
    }

    static func launch(for target: QuickConnectTarget) -> SSHLaunch {
        // 사용자가 직접 입력한 인자를 공백으로 나눠 쓴다 (예: "-p 2222 admin@10.0.0.5")
        SSHLaunch(
            title: target.displayName,
            user: target.user,
            arguments: target.arguments.split(whereSeparator: \.isWhitespace).map(String.init),
            hostNames: [target.host])
    }

    /// ["ssh", 인자...] 를 셸에 안전한 명령줄로 만든다.
    static func commandLine(_ arguments: [String]) -> String {
        (["ssh"] + arguments.map(shellQuote)).joined(separator: " ")
    }

    /// 셸 특수 문자가 있으면 작은따옴표로 감싼다.
    static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_~"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }
}
