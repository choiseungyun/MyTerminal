import XCTest
@testable import MyTerminal

/// 자동 업데이트(Sparkle) 설정
final class AppUpdaterTests: XCTestCase {
    /// 배포용 앱이 업데이트를 찾고 확인할 수 있게 Info.plist 에 들어 있어야 하는 값
    func testInfoPlistHasFeedAndPublicKey() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let feed = try XCTUnwrap(info["SUFeedURL"] as? String)
        XCTAssertTrue(feed.hasPrefix("https://"), "업데이트 목록은 https 로 받는다")
        XCTAssertTrue(feed.hasSuffix("/releases/latest/download/appcast.xml"), "항상 최신 릴리스의 목록")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "Ed25519 공개 키 (32바이트)")
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false, "사용 환경 정보는 보내지 않는다")
    }

    /// 개발 빌드·테스트에서는 업데이트를 켜지 않는다 (개발 중인 앱이 공개 버전으로 바뀌지 않도록)
    @MainActor
    func testDisabledInDevelopmentAndTests() {
        XCTAssertFalse(AppUpdater.isEnabled(bundle: .main, environment: ProcessInfo.processInfo.environment))
        XCTAssertFalse(AppUpdater.shared.isAvailable)
        XCTAssertFalse(AppUpdater.shared.canCheckForUpdates)
    }
}
