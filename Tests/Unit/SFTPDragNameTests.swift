import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import MyTerminal

/// 회귀: SFTP 탭에서 서버 파일을 왼쪽 칸으로 끌면 "a.sql.gz" 가 "a.sql.gz.gz" 로 저장됨
final class SFTPDragNameTests: XCTestCase {
    func testExactNameWins() {
        XCTAssertEqual(SFTPDragName.resolvedName(exact: "backup.sql.gz", suggested: "backup.sql.gz.gz", fileName: "backup.sql.gz.gz"),
                       "backup.sql.gz")
        XCTAssertEqual(SFTPDragName.resolvedName(exact: nil, suggested: "b.txt", fileName: "tmp"), "b.txt")
        XCTAssertEqual(SFTPDragName.resolvedName(exact: nil, suggested: nil, fileName: "tmp.bin"), "tmp.bin")
    }

    func testRejectsPathTricks() {
        XCTAssertEqual(SFTPDragName.resolvedName(exact: "../../etc/passwd", suggested: nil, fileName: "f"), "passwd")
        XCTAssertEqual(SFTPDragName.resolvedName(exact: "..", suggested: "", fileName: "f"), "f")
    }

    /// 끄는 쪽이 싣는 원래 이름을 받는 쪽이 읽고, 파일 형식은 앱 전용 형식이 아닌 것을 고른다
    func testProviderCarriesExactName() async throws {
        let provider = NSItemProvider()
        provider.suggestedName = "backup_20261114_030001.sql.gz"
        let type = UTType(filenameExtension: "gz")!
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { _ in nil }
        SFTPDragName.register("backup_20261114_030001.sql.gz", on: provider)

        XCTAssertEqual(SFTPDragName.fileType(of: provider), type.identifier)
        let name = await SFTPDragName.load(from: provider)
        XCTAssertEqual(name, "backup_20261114_030001.sql.gz")

        let plain = NSItemProvider(object: URL(fileURLWithPath: "/tmp/x") as NSURL)
        let none = await SFTPDragName.load(from: plain)
        XCTAssertNil(none, "Finder 에서 온 파일에는 없다")
    }
}
