//
//  StorageTests.swift
//  ProxyTunnelCoreTests
//
//  §21: Keychain operations, and the profile store that sits on top of them.
//
//  The Keychain half runs against the real Security framework on the iOS
//  Simulator. That is genuinely useful — it exercises the add/update/delete paths
//  and the OSStatus mapping — but it is not the same as a device, where the
//  access group is derived from the code signature. `docs/TESTING.md` says so.
//

import XCTest
import Security
@testable import ProxyTunnelCore

final class KeychainSecretStoreTests: XCTestCase {

    private var store: KeychainSecretStore!
    private let service = "io.github.kylosonic.proxytunnel.tests.\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = KeychainSecretStore(service: service)

        // An iOS process with no keychain access group cannot use the Keychain at
        // all: the default group is derived from the code signature, and a
        // host-less unit-test bundle signed ad-hoc on the Simulator has none. That
        // is a property of the test process, not of `KeychainSecretStore`, so skip
        // with the reason instead of reporting a failure that means nothing.
        do {
            try store.setSecret("availability-probe", for: "availability-probe")
            try store.deleteSecret(for: "availability-probe")
        } catch let error as SecretStoreError where error.isEntitlementProblem {
            throw XCTSkip("""
            The Keychain is unavailable to this test process: \(error)

            \(KeychainSecretStoreTests.unavailabilityExplanation)
            """)
        } catch {
            throw XCTSkip("The Keychain is unavailable to this test process (\(error)).\n\n\(KeychainSecretStoreTests.unavailabilityExplanation)")
        }
    }

    static let unavailabilityExplanation = """
    iOS derives an app's default keychain access group from its code signature \
    (team identifier + bundle identifier). A host-less XCTest bundle has no such \
    identity, so SecItemAdd returns errSecMissingEntitlement (-34018). To exercise \
    these tests, run them from Xcode against a signed test host, or on a device \
    build. See docs/TESTING.md.
    """

    override func tearDown() {
        if let keys = try? store.allKeys() {
            for key in keys { try? store.deleteSecret(for: key) }
        }
        store = nil
        super.tearDown()
    }

    func testStoresAndReadsBackASecret() throws {
        try store.setSecret("example-password", for: "acct-1")
        XCTAssertEqual(try store.secret(for: "acct-1"), "example-password")
    }

    func testOverwritingASecretUpdatesItRatherThanDuplicating() throws {
        try store.setSecret("first", for: "acct-1")
        try store.setSecret("second", for: "acct-1")
        XCTAssertEqual(try store.secret(for: "acct-1"), "second")
        XCTAssertEqual(try store.allKeys().filter { $0 == "acct-1" }.count, 1)
    }

    func testMissingSecretReturnsNilRatherThanThrowing() throws {
        XCTAssertNil(try store.secret(for: "does-not-exist"))
    }

    func testDeleteIsIdempotent() throws {
        try store.setSecret("x", for: "acct-1")
        try store.deleteSecret(for: "acct-1")
        XCTAssertNil(try store.secret(for: "acct-1"))
        XCTAssertNoThrow(try store.deleteSecret(for: "acct-1"))
    }

    func testAllKeysListsWhatWasStored() throws {
        try store.setSecret("a", for: "one")
        try store.setSecret("b", for: "two")
        XCTAssertEqual(try store.allKeys(), ["one", "two"])
    }

    func testHandlesNonASCIIAndLongSecrets() throws {
        let secret = String(repeating: "pässwörd🔐", count: 200)
        try store.setSecret(secret, for: "unicode")
        XCTAssertEqual(try store.secret(for: "unicode"), secret)
    }

    func testDefaultStoreUsesNoExplicitAccessGroup() {
        let defaultStore = KeychainSecretStore()
        XCTAssertFalse(defaultStore.isSharedWithExtension,
                       "an explicit access group needs a keychain-access-groups entitlement that a free-Apple-ID build does not have")
    }

}

/// Error-mapping tests for the Keychain store. These need no Keychain access
/// themselves, so they live outside `KeychainSecretStoreTests` and still run when
/// that class is skipped.
final class KeychainErrorMappingTests: XCTestCase {

    func testStatusMessagesAreHumanReadable() {
        XCTAssertFalse(KeychainSecretStore.message(for: errSecItemNotFound).isEmpty)
        // `SecCopyErrorMessageString` returns a generic "OSStatus N" string for
        // values it does not know, rather than nil, so assert on the shape rather
        // than on an exact fallback.
        let unknown = KeychainSecretStore.message(for: -99999)
        XCTAssertFalse(unknown.isEmpty)
        XCTAssertTrue(unknown.contains("99999") || unknown == "unknown", unknown)
    }

    func testEntitlementErrorsAreRecognised() {
        XCTAssertTrue(SecretStoreError.missingEntitlement(errSecMissingEntitlement).isEntitlementProblem)
        XCTAssertTrue(SecretStoreError.unavailable.isEntitlementProblem)
        XCTAssertFalse(SecretStoreError.corruptedValue.isEntitlementProblem)
        XCTAssertFalse(SecretStoreError.unexpectedStatus(-1).isEntitlementProblem)
    }

    func testErrorDescriptionsAreActionable() {
        let message = SecretStoreError.missingEntitlement(errSecMissingEntitlement).description
        XCTAssertTrue(message.contains("keychain-access-groups"), message)
    }
}

final class InMemorySecretStoreTests: XCTestCase {

    func testBehavesLikeTheKeychain() throws {
        let store = InMemorySecretStore()
        try store.setSecret("one", for: "a")
        XCTAssertEqual(try store.secret(for: "a"), "one")
        try store.setSecret("two", for: "a")
        XCTAssertEqual(try store.secret(for: "a"), "two")
        try store.deleteSecret(for: "a")
        XCTAssertNil(try store.secret(for: "a"))
        XCTAssertEqual(try store.allKeys(), [])
    }

    func testSeeding() throws {
        let store = InMemorySecretStore(seed: ["k": "v"])
        XCTAssertEqual(try store.secret(for: "k"), "v")
    }
}

final class ProfileStoreTests: XCTestCase {

    private var directory: URL!
    private var secrets: InMemorySecretStore!
    private var store: ProfileStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyTunnelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        secrets = InMemorySecretStore()
        store = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"), secrets: secrets)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func input(name: String = "My Proxy", password: String? = "example-password") -> ValidatedProxyInput {
        ValidatedProxyInput(
            name: name,
            host: "example.proxy.com",
            port: 12345,
            protocolType: .socks5,
            username: "example-user",
            password: password,
            notes: nil,
            isMock: false
        )
    }

    func testAddStoresMetadataAndSecretSeparately() throws {
        let profile = try store.add(input())

        // The password must be in the secret store …
        let reference = try XCTUnwrap(profile.passwordReference)
        XCTAssertEqual(try secrets.secret(for: reference), "example-password")

        // … and must not appear anywhere in the JSON document.
        let json = try String(contentsOf: directory.appendingPathComponent("profiles.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("example-password"))
        XCTAssertTrue(json.contains("example.proxy.com"))
    }

    func testFirstProfileBecomesTheSelectedOne() throws {
        let profile = try store.add(input())
        XCTAssertEqual(store.selectedProfileID, profile.id)
        XCTAssertEqual(store.selectedProfile?.id, profile.id)
    }

    func testUpdateKeepsThePasswordWhenNoneIsGiven() throws {
        let profile = try store.add(input())
        var edited = profile
        edited.name = "Renamed"
        try store.update(edited, password: .none)

        XCTAssertEqual(store.profile(id: profile.id)?.name, "Renamed")
        XCTAssertEqual(try store.password(for: profile), "example-password")
    }

    func testUpdateReplacesThePassword() throws {
        let profile = try store.add(input())
        try store.update(profile, password: .some(.some("new-password")))
        XCTAssertEqual(try store.password(for: profile), "new-password")
    }

    func testUpdateRemovesThePasswordWhenAsked() throws {
        let profile = try store.add(input())
        try store.update(profile, password: .some(nil))
        XCTAssertNil(store.profile(id: profile.id)?.passwordReference)
        XCTAssertEqual(try secrets.allKeys().count, 0)
    }

    func testDeleteRemovesTheSecretToo() throws {
        let profile = try store.add(input())
        try store.delete(id: profile.id)
        XCTAssertNil(store.profile(id: profile.id))
        XCTAssertEqual(try secrets.allKeys().count, 0)
    }

    func testSelectRejectsAnUnknownId() {
        XCTAssertThrowsError(try store.select(id: UUID()))
    }

    func testPersistsAcrossInstances() throws {
        let profile = try store.add(input())
        let reloaded = ProfileStore(
            fileURL: directory.appendingPathComponent("profiles.json"),
            secrets: secrets
        )
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.selectedProfileID, profile.id)
    }

    func testSurvivesACorruptFileWithoutLosingIt() throws {
        let url = directory.appendingPathComponent("profiles.json")
        try Data("{ this is not json".utf8).write(to: url)

        let recovered = ProfileStore(fileURL: url, secrets: secrets)
        XCTAssertTrue(recovered.profiles.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the damaged file must be kept, not deleted")
    }

    func testIsMissingStoredPasswordDetectsARestoredDevice() throws {
        let profile = try store.add(input())
        XCTAssertFalse(store.isMissingStoredPassword(for: profile))

        // Simulate the Keychain item being gone (what a device restore looks like).
        let reference = try XCTUnwrap(profile.passwordReference)
        try secrets.deleteSecret(for: reference)
        XCTAssertTrue(store.isMissingStoredPassword(for: profile))
    }

    func testCredentialReturnsNilWhenNoUsernameIsSet() throws {
        let noAuth = ValidatedProxyInput(
            name: "open", host: "h.example.com", port: 1080,
            protocolType: .socks5, username: nil, password: nil, notes: nil, isMock: false
        )
        let profile = try store.add(noAuth)
        XCTAssertNil(try store.credential(for: profile))
    }

    func testEnabledFiltering() throws {
        let profile = try store.add(input())
        try store.setEnabled(false, for: profile.id)
        XCTAssertTrue(store.enabledProfiles.isEmpty)
        try store.setEnabled(true, for: profile.id)
        XCTAssertEqual(store.enabledProfiles.count, 1)
    }
}

final class AppSettingsStoreTests: XCTestCase {

    func testDefaultsAreSane() {
        let settings = AppSettings()
        XCTAssertFalse(settings.autoConnectOnLaunch)
        XCTAssertFalse(settings.blockTrafficWhenTunnelDown)
        XCTAssertTrue(settings.allowIPv6)
        XCTAssertEqual(settings.dnsServers, TunnelNetworkDefaults.dnsServers)
        XCTAssertFalse(settings.useMockMode, "mock mode must never default to on")
    }

    func testRoundTrips() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).json")
        var settings = AppSettings()
        settings.allowIPv6 = false
        settings.tracePackets = true
        settings.dnsServers = ["9.9.9.9"]
        AppSettingsStore.save(settings, to: url)

        let loaded = AppSettingsStore.load(from: url)
        XCTAssertEqual(loaded, settings)
        try? FileManager.default.removeItem(at: url)
    }

    func testFallsBackToDefaultsOnAMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")
        XCTAssertEqual(AppSettingsStore.load(from: url), AppSettings())
    }

    func testIPv6OffIsReportedAsALeak() {
        var settings = AppSettings()
        XCTAssertFalse(settings.hasIPv6LeakByDesign)
        settings.allowIPv6 = false
        XCTAssertTrue(settings.hasIPv6LeakByDesign)
    }
}
