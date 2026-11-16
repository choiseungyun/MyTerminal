import Combine
import Foundation
import Sparkle

/// 자동 업데이트 (Sparkle).
///
/// - 업데이트 목록: Info.plist 의 `SUFeedURL` (항상 최신 GitHub 릴리스의 appcast.xml)
/// - 받은 파일은 `SUPublicEDKey` 와 맞는 EdDSA 서명이 있어야 설치된다.
/// - 처음 실행 다음번에 "자동으로 확인할까요?" 를 한 번 묻는다 (Sparkle 기본 동작).
/// - 개발 빌드(Debug)와 테스트에서는 켜지 않는다: 개발 중인 앱이 공개 버전으로 바뀌면 안 되므로.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// 이 빌드에서 업데이트를 쓸 수 있는지 (배포용 빌드이고 업데이트 목록 주소가 있을 때)
    let isAvailable: Bool
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheck: Date?

    private let controller: SPUStandardUpdaterController?
    private var observers: [AnyCancellable] = []

    private init() {
        if Self.isEnabled(bundle: .main, environment: ProcessInfo.processInfo.environment) {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            self.controller = controller
            isAvailable = true
            let updater = controller.updater
            observers.append(updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 })
            observers.append(updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
                .sink { [weak self] in self?.lastCheck = $0 })
        } else {
            controller = nil
            isAvailable = false
        }
    }

    /// 업데이트를 켤지: Debug 빌드·테스트가 아니고, Info.plist 에 업데이트 목록 주소와 공개 키가 있을 때
    nonisolated static func isEnabled(bundle: Bundle, environment: [String: String]) -> Bool {
        #if DEBUG
        return false
        #else
        guard environment["XCTestConfigurationFilePath"] == nil else { return false }
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
        #endif
    }

    /// 메뉴 "업데이트 확인…": 결과(새 버전 있음·최신임)를 창으로 보여 준다
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// 하루에 한 번 정도 자동으로 확인
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    /// 새 버전을 미리 받아 두었다가 앱을 끝낼 때 설치
    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    /// 지금 버전 (예: "0.1.2 (3)")
    nonisolated static var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
