import XCTest
@testable import CodePax

final class ConnectionTests: XCTestCase {
    @MainActor
    func testAutomaticReconnectOnlyWhileConversationIsInForeground() async {
        let model = ConnectionModel()
        model.profile.host = ""
        XCTAssertFalse(model.allowsAutomaticReconnect)
        model.foregroundChanged(true, workspaceVisible: false)
        await model.connect(automatically: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
        model.foregroundChanged(true, workspaceVisible: true)
        XCTAssertTrue(model.allowsAutomaticReconnect)
        model.foregroundChanged(false, workspaceVisible: true)
        XCTAssertFalse(model.allowsAutomaticReconnect)
        model.foregroundChanged(true, workspaceVisible: true)
        XCTAssertTrue(model.allowsAutomaticReconnect)
        model.foregroundChanged(true, workspaceVisible: false)
        XCTAssertFalse(model.allowsAutomaticReconnect)
        await model.connect(automatically: true)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testSavedCardKeepsEnteredPasswordOnlyForTheSameServer() async throws {
        let defaults = UserDefaults.standard
        let keys = ["savedServers", "selectedServerID", "automaticReconnectEnabled", "lastConnectedServerID"]
        let original = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, original) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "automaticReconnectEnabled")
        var saved = ServerProfile()
        saved.host = "card-test.invalid"
        saved.username = "test"
        defaults.set(try JSONEncoder().encode([saved]), forKey: "savedServers")
        defaults.set(saved.id, forKey: "selectedServerID")
        let model = ConnectionModel()
        model.password = "in-memory-test-password"
        await model.selectServer(saved.id)
        XCTAssertEqual(model.password, "in-memory-test-password")
        // An edited endpoint must never reuse a password belonging to another host.
        model.profile.host = "different-host.invalid"
        model.password = "another-test-password"
        await model.selectServer(saved.id)
        XCTAssertEqual(model.profile.host, saved.host)
        XCTAssertTrue(model.password.isEmpty)
    }

    func testLegacyProfileMigratesWithoutPassword() throws {
        let data = Data(#"{"host":"10.10.0.172","port":"22","username":"developer"}"#.utf8)
        let profile = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertFalse(profile.rememberPassword)
        XCTAssertFalse(profile.id.isEmpty)
        let encoded = try JSONEncoder().encode(profile)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(fields["password"])
        XCTAssertEqual(try JSONDecoder().decode(ServerProfile.self, from: encoded).id, profile.id)
    }

    func testSavedCredentialIsBoundToServerPortUserAndProfile() {
        let profile = ServerProfile()
        var other = profile
        other.host = "another-host"
        XCTAssertNotEqual(profile.credentialAccount, other.credentialAccount)
        other = profile; other.port = "2222"
        XCTAssertNotEqual(profile.credentialAccount, other.credentialAccount)
        other = profile; other.username = "another-user"
        XCTAssertNotEqual(profile.credentialAccount, other.credentialAccount)
        other = profile; other.id = UUID().uuidString
        XCTAssertNotEqual(profile.credentialAccount, other.credentialAccount)
    }

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
