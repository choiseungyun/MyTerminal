import Foundation

/// 서버 파일을 끌 때 원래 파일 이름을 앱 안에서만 함께 넘긴다.
///
/// 시스템 끌어 놓기를 거치면 받는 쪽의 파일 이름이 형식에 맞춰 다시 만들어져
/// "a.sql.gz" 가 "a.sql.gz.gz" 처럼 확장자가 한 번 더 붙을 수 있다.
/// 그래서 정확한 이름을 앱 전용 형식(이 앱에서만 보임)으로 같이 싣고, 앱 안에 놓을 때는 그 이름을 쓴다.
enum SFTPDragName {
    static let typeIdentifier = "kr.weare.myterminal.sftp-file-name"

    static func register(_ name: String, on provider: NSItemProvider) {
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(Data(name.utf8), nil)
            return nil
        }
    }

    /// 실린 원래 이름 (없으면 nil)
    static func load(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) })
            }
        }
    }

    /// 파일 내용을 받을 형식 (앱 전용 이름 형식은 제외)
    static func fileType(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { $0 != typeIdentifier }
    }

    /// 저장할 이름: 원래 이름 > 시스템이 알려 준 이름 > 받은 임시 파일 이름.
    /// 경로 문자("/", "..")는 쓰지 않는다.
    static func resolvedName(exact: String?, suggested: String?, fileName: String) -> String {
        for candidate in [exact, suggested] {
            guard let candidate else { continue }
            let name = (candidate as NSString).lastPathComponent
            if !name.isEmpty, name != ".", name != "..", !name.contains("/") { return name }
        }
        return fileName
    }
}

/// 앱 안에서 서버 칸 → 이 Mac 칸으로 끄는 중인 파일.
///
/// 시스템 끌어 놓기의 "나중에 넘겨줄 파일"(파일 약속)을 거치면 받는 쪽 이름에 확장자가 한 번 더 붙고,
/// 끝나지 않은 약속이 남아 앱 종료가 멈추는 일이 있었다. 그래서 끌기를 시작할 때 어떤 서버 파일인지 기록해 두고,
/// 앱 안의 이 Mac 칸에 놓이면 시스템이 넘겨주는 파일을 받지 않고 서버에서 바로 내려받는다.
/// (Finder 로 끌어낼 때는 지금처럼 시스템 끌어 놓기를 쓴다)
@MainActor
enum SFTPInAppDrag {
    struct Session {
        let browser: RemoteBrowser
        let entries: [SFTPEntry]
        let started: Date
    }

    private(set) static var current: Session?

    /// 서버 칸에서 끌기를 시작할 때
    static func begin(browser: RemoteBrowser, entries: [SFTPEntry], now: Date = Date()) {
        current = Session(browser: browser, entries: entries, started: now)
    }

    /// 이 Mac 칸에 놓을 때: 같은 끌기에서 온 것이면 꺼내고 지운다.
    /// Finder 파일(파일 URL)이 섞여 있거나, 이름이 다르거나, 오래된 기록이면 nil.
    static func take(for providers: [NSItemProvider], now: Date = Date(), maxAge: TimeInterval = 120) -> Session? {
        guard let session = current else { return nil }
        guard now.timeIntervalSince(session.started) <= maxAge,
              !providers.isEmpty,
              !providers.contains(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }),
              providers.allSatisfy({ provider in
                  // 시스템이 확장자를 덧붙일 수 있으므로 앞부분이 원래 이름과 같은지만 본다
                  guard let name = provider.suggestedName else { return true }
                  return session.entries.contains { name.hasPrefix($0.name) || $0.name.hasPrefix(name) }
              })
        else { return nil }
        current = nil
        return session
    }

    static func reset() { current = nil }
}
