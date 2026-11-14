import XCTest
@testable import MyTerminal

final class HostFormTests: XCTestCase {
    func testBuildTrimsAndParses() throws {
        var form = HostForm(host: SSHHost())
        form.host.hostname = "  web-01  "
        form.host.name = " 웹 "
        form.host.user = ""
        form.portText = " 2222 "
        form.tagsText = "web, , prod ,"

        let host = try form.build()
        XCTAssertEqual(host.hostname, "web-01")
        XCTAssertEqual(host.name, "웹")
        XCTAssertNil(host.user, "빈 문자열은 nil 로 저장")
        XCTAssertEqual(host.port, 2222)
        XCTAssertEqual(host.tags, ["web", "prod"])
    }

    func testEmptyPortMeansDefault() throws {
        var form = HostForm(host: SSHHost())
        form.host.hostname = "x"
        form.portText = ""
        XCTAssertNil(try form.build().port)
    }

    func testValidationErrors() {
        var form = HostForm(host: SSHHost())
        XCTAssertEqual(form.validationError, .missingAddress)

        form.host.hostname = "x"
        for bad in ["0", "65536", "abc", "-1"] {
            form.portText = bad
            XCTAssertEqual(form.validationError, .invalidPort, bad)
        }
        form.portText = "22"
        XCTAssertNil(form.validationError)
    }

    func testSSHConfigHostNeedsNoAddress() throws {
        var host = SSHHost()
        host.sshConfigAlias = "prod"
        XCTAssertEqual(try HostForm(host: host).build().hostname, "prod")
    }

    func testRoundTripFromSavedHost() throws {
        var host = SSHHost()
        host.hostname = "db"
        host.port = 2200
        host.tags = ["a", "b"]
        let form = HostForm(host: host)
        XCTAssertEqual(form.portText, "2200")
        XCTAssertEqual(form.tagsText, "a, b")
        XCTAssertEqual(try form.build().tags, ["a", "b"])
    }
}
