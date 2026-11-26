import Foundation

/// ssh 접속 정보로 SFTP 연결을 연다: `/usr/bin/ssh -s <연결 재사용 옵션> <접속 인자> sftp`
///
/// 터미널이 같은 호스트에 이미 접속해 있으면 연결 재사용으로 인증 없이 바로 열린다.
/// 아니면 ssh 가 새로 인증한다 (키·에이전트·저장된 비밀번호). 터미널이 없으므로
/// 호스트 키 확인이나 직접 입력이 필요한 질문에는 답할 수 없다 → 알기 쉬운 오류로 바꿔 알린다.
final class SFTPConnection {
    let launch: SSHLaunch
    let client: SFTPClient
    private var askpassToken: String?

    private init(launch: SSHLaunch, client: SFTPClient, askpassToken: String?) {
        self.launch = launch
        self.client = client
        self.askpassToken = askpassToken
    }

    deinit { close() }

    static func open(_ launch: SSHLaunch) async throws -> SFTPConnection {
        var environment = ProcessInfo.processInfo.environment
        var token: String?
        if let askpass = AskpassServer.shared.environment(for: launch) {
            environment.merge(askpass.environment) { _, new in new }
            token = askpass.token
        }

        let transport: ProcessTransport
        do {
            transport = try ProcessTransport(
                executable: "/usr/bin/ssh",
                arguments: arguments(for: launch),
                environment: environment)
        } catch {
            if let token { AskpassServer.shared.unregister(token) }
            throw error
        }

        do {
            let client = try await SFTPClient(transport: transport)
            return SFTPConnection(launch: launch, client: client, askpassToken: token)
        } catch {
            if let token { AskpassServer.shared.unregister(token) }
            throw friendlyError(error, stderr: await transport.errorTextAfterExit())
        }
    }

    static func arguments(for launch: SSHLaunch) -> [String] {
        ["-s"]
            + SSHMultiplex.connectionOptions
            + ["-o", "ServerAliveInterval=30"]
            + launch.arguments
            + ["sftp"]
    }

    func close() {
        client.close()
        if let askpassToken {
            AskpassServer.shared.unregister(askpassToken)
            self.askpassToken = nil
        }
    }

    /// ssh 오류 메시지를 사용자가 할 일이 보이는 문장으로 바꾼다.
    static func friendlyError(_ error: Error, stderr: String) -> Error {
        let text = stderr.lowercased()
        let message: String
        if text.contains("host key verification failed") {
            message = "처음 접속하는 서버라 호스트 키 확인이 필요합니다. 먼저 터미널로 한 번 접속해 확인(yes)한 뒤 다시 여세요."
        } else if text.contains("permission denied") {
            message = "인증에 실패했습니다. 터미널로 먼저 접속해 두거나, 호스트에 비밀번호를 저장하세요."
        } else if text.contains("could not resolve hostname") {
            message = "호스트 이름을 찾을 수 없습니다."
        } else if text.contains("connection refused") {
            message = "서버가 연결을 거부했습니다 (포트·ssh 서비스 확인)."
        } else if text.contains("timed out") {
            message = "연결 시간이 초과되었습니다."
        } else if text.contains("subsystem request failed") {
            message = "서버에서 SFTP 를 사용할 수 없습니다."
        } else {
            return error
        }
        return SFTPError.connectionFailed(message)
    }
}
