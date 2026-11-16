import Foundation
import OSLog

/// 끌어 놓기 기록 (`log show --predicate 'subsystem == "kr.weare.myterminal" AND category == "drag"'`). 파일 이름은 남기지 않는다.
let dragLog = Logger(subsystem: "kr.weare.myterminal", category: "drag")

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
///
/// 앱 안에 놓아도 시스템이 끌기에 실린 파일을 따로 요청하는 일이 있어, 같은 파일을 두 번 받았다
/// (한 번은 놓은 폴더로, 한 번은 임시 폴더로). 그래서 앱 안에서 처리한 끌기를 기록해 두고,
/// 파일 요청이 오면 `shouldSkipPromise` 로 확인해 받지 않는다.
@MainActor
enum SFTPInAppDrag {
    struct Session {
        let id = UUID()
        let browser: RemoteBrowser
        let entries: [SFTPEntry]
        let started: Date
    }

    private(set) static var current: Session?
    /// 앱 안에서 이미 내려받은 끌기 (최근 것 몇 개만)
    private static var handled: [UUID] = []

    /// 시스템의 파일 요청이 앱 안에 놓기와 거의 동시에 오므로, 이만큼 기다렸다가 확인한다
    static let promiseDelay: Duration = .milliseconds(400)

    /// 서버 칸에서 끌기를 시작할 때. 돌려준 id 로 나중에 `shouldSkipPromise` 를 확인한다.
    @discardableResult
    static func begin(browser: RemoteBrowser, entries: [SFTPEntry], now: Date = Date()) -> UUID {
        let session = Session(browser: browser, entries: entries, started: now)
        current = session
        return session.id
    }

    /// 시스템이 끌기에 실린 파일을 요청했을 때: 이 끌기를 앱 안에서 이미 받았으면 true (다시 받지 않는다)
    static func shouldSkipPromise(for id: UUID) -> Bool {
        handled.contains(id)
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
        handled.append(session.id)
        if handled.count > 10 { handled.removeFirst(handled.count - 10) }
        return session
    }

    static func reset() {
        current = nil
        handled = []
    }
}
