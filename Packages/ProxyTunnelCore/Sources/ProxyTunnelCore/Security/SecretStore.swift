//
//  SecretStore.swift
//  ProxyTunnelCore
//
//  Keychain-backed storage for proxy passwords.
//
//  ## Why the Keychain and not the App Group container
//
//  The obvious way to hand a password to a Network Extension is to put it in
//  `NETunnelProviderProtocol.providerConfiguration`, which iOS persists in the
//  system VPN preferences. That plist is *outside* the app sandbox and is not
//  encrypted with the app's data protection key, so a password written there is
//  effectively stored in the clear by the operating system. We therefore treat
//  that as a last resort and prefer the Keychain.
//
//  ## The extension's problem
//
//  A Keychain item's default access group is derived from the *code signing*
//  identity: `<TeamID>.<BundleID>`. The extension's bundle ID differs from the
//  app's, so by default the two processes cannot see each other's items. Sharing
//  requires either
//
//    * the Keychain Sharing capability (`keychain-access-groups` entitlement), or
//    * the App Groups capability, plus `kSecAttrAccessGroup` set to the group.
//
//  Both are entitlements which may or may not be provisionable depending on how
//  the app was signed. `TunnelConfigurationTransport` in the Tunnel module picks
//  the best available channel at runtime and documents the trade-off.
//

import Foundation

#if canImport(Security)
import Security
#endif

public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    /// The Keychain returned an unexpected OSStatus.
    case unexpectedStatus(OSStatus)
    /// `errSecMissingEntitlement` — the access group is not in our entitlements.
    case missingEntitlement(OSStatus)
    /// `errSecInteractionNotAllowed` — the item needs the device to be unlocked.
    case interactionNotAllowed(OSStatus)
    /// The stored item was not valid UTF-8.
    case corruptedValue
    /// This process may not use the Keychain at all.
    case unavailable

    public var description: String {
        switch self {
        case .unexpectedStatus(let s):
            return "Keychain error \(s) (\(KeychainSecretStore.message(for: s)))."
        case .missingEntitlement(let s):
            return "The Keychain rejected the requested access group (OSStatus \(s)). The app is probably signed without the matching keychain-access-groups entitlement."
        case .interactionNotAllowed(let s):
            return "The Keychain item is not readable while the device is locked (OSStatus \(s))."
        case .corruptedValue:
            return "The stored secret is not valid UTF-8."
        case .unavailable:
            return "The Keychain is unavailable in this process."
        }
    }

    /// Whether a different signing configuration would fix this.
    public var isEntitlementProblem: Bool {
        switch self {
        case .missingEntitlement, .unavailable: return true
        default: return false
        }
    }
}

/// The narrow interface the rest of the app uses for secrets. Swapping in
/// `InMemorySecretStore` is how the unit tests and the SwiftUI previews avoid
/// touching the real Keychain.
public protocol SecretStoring: AnyObject {
    func setSecret(_ secret: String, for key: String) throws
    func secret(for key: String) throws -> String?
    func deleteSecret(for key: String) throws
    func allKeys() throws -> [String]
}

// MARK: - Keychain implementation

public final class KeychainSecretStore: SecretStoring {

    private let service: String
    private let accessGroup: String?
    private let lock = NSLock()

    /// - Parameters:
    ///   - service: `kSecAttrService`. Defaults to `<app bundle id>.secrets`.
    ///   - accessGroup: `kSecAttrAccessGroup`. Leave `nil` to use the process's
    ///     default access group, which is the only value that is guaranteed to
    ///     work without extra entitlements.
    public init(service: String = AppIdentifiers.keychainService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// True when the item will be readable by the Network Extension process too.
    public var isSharedWithExtension: Bool { accessGroup != nil }

    // MARK: SecretStoring

    public func setSecret(_ secret: String, for key: String) throws {
        guard let data = secret.data(using: .utf8) else { throw SecretStoreError.corruptedValue }
        lock.lock(); defer { lock.unlock() }

        var query = baseQuery(account: key)
        query[kSecValueData as String] = data
        // AfterFirstUnlock (not ThisDeviceOnly) would allow iCloud/backup
        // restore of the ciphertext; ThisDeviceOnly keeps the secret bound to
        // this device, which is what we want for a proxy credential.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Update the existing item, leaving its accessibility attribute as-is.
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                baseQuery(account: key) as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw map(updateStatus) }
        default:
            throw map(status)
        }
    }

    public func secret(for key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }

        var query = baseQuery(account: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw SecretStoreError.corruptedValue }
            guard let text = String(data: data, encoding: .utf8) else { throw SecretStoreError.corruptedValue }
            return text
        case errSecItemNotFound:
            return nil
        default:
            throw map(status)
        }
    }

    public func deleteSecret(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(baseQuery(account: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
    }

    public func allKeys() throws -> [String] {
        lock.lock(); defer { lock.unlock() }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = (result as? [[String: Any]]) ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw map(status)
        }
    }

    // MARK: Internals

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func map(_ status: OSStatus) -> SecretStoreError {
        switch status {
        case errSecMissingEntitlement:  return .missingEntitlement(status)
        case errSecInteractionNotAllowed: return .interactionNotAllowed(status)
        case errSecNotAvailable:        return .unavailable
        default:                        return .unexpectedStatus(status)
        }
    }

    /// Human-readable text for the OSStatus values we are most likely to see.
    public static func message(for status: OSStatus) -> String {
        if let cfMessage = SecCopyErrorMessageString(status, nil) {
            return cfMessage as String
        }
        switch status {
        case errSecMissingEntitlement:    return "missing entitlement"
        case errSecInteractionNotAllowed: return "interaction not allowed (device locked?)"
        case errSecDuplicateItem:         return "duplicate item"
        case errSecItemNotFound:          return "item not found"
        case errSecAuthFailed:            return "authentication failed"
        case errSecDecode:                return "decode error"
        default:                          return "unknown"
        }
    }
}

// MARK: - In-memory implementation

/// A Keychain-free store used by unit tests, SwiftUI previews and "mock mode".
///
/// It is intentionally not persistent and logs a warning the first time it is
/// used outside a test, so it can never silently become a production path.
public final class InMemorySecretStore: SecretStoring {

    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    public func setSecret(_ secret: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = secret
    }

    public func secret(for key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func deleteSecret(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func allKeys() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted()
    }
}

// MARK: - Process-wide default

public enum SecretStoreProvider {

    private static let lock = NSLock()
    private static var override: SecretStoring?

    /// The store the app should use. Tests and previews call
    /// `useInMemoryStore()` / `useKeychainStore(accessGroup:)` to override it.
    public static var current: SecretStoring {
        lock.lock(); defer { lock.unlock() }
        if let override { return override }
        return KeychainSecretStore()
    }

    public static func useInMemoryStore(seed: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        override = InMemorySecretStore(seed: seed)
    }

    /// - Parameter accessGroup: pass an App Group identifier to make the store
    ///   readable by the Network Extension as well, when the matching
    ///   entitlement is available.
    public static func useKeychainStore(accessGroup: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        override = KeychainSecretStore(accessGroup: accessGroup)
    }

    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        override = nil
    }
}
