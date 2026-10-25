import XCTest
@testable import CodexIPad

final class ConnectionTests: XCTestCase {
    func testRejectsInvalidPortsAndURLInput() {
        for port in ["0", "65536", "abc", "-1"] {
            var profile = ServerProfile()
            profile.port = port
            XCTAssertThrowsError(try profile.validated())
        }
        var profile = ServerProfile()
        profile.host = "ssh://example.com"
        XCTAssertThrowsError(try profile.validated())
        profile.host = ""
        XCTAssertThrowsError(try profile.validated())
    }

    func testNormalizesProfileAndSupportsIPv6() throws {
        var profile = ServerProfile()
        profile.host = " 2001:db8::1 "
        profile.username = " developer "
        profile.port = " 2222 "
        let validated = try profile.validated()
        XCTAssertEqual(validated.host, "2001:db8::1")
        XCTAssertEqual(validated.username, "developer")
        XCTAssertEqual(validated.portNumber, 2222)
        XCTAssertEqual(validated.endpoint, "[2001:db8::1]:2222")
    }

    func testFingerprintUsesOpenSSHKeyBytesAndIgnoresComments() throws {
        // SHA256("abc"), encoded like an OpenSSH SHA256 fingerprint (no '=' padding).
        let expected = "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0"
        XCTAssertEqual(try HostFingerprint.make(openSSHKey: "ssh-ed25519 YWJj comment"), expected)
        XCTAssertThrowsError(try HostFingerprint.make(openSSHKey: "invalid"))
    }
}
