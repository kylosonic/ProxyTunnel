//
//  ProfileStore.swift
//  ProxyTunnelCore
//
//  Persistence for proxy profiles.
//
//  Two stores, on purpose:
//
//    * non-secret metadata  →  one JSON document in Application Support
//    * passwords            →  the iOS Keychain, via `SecretStoring`
//
//  The split is enforced by `ProxyProfile` having no password property at all, so
//  there is no way for a password to end up in the JSON document by accident.
//

import Foundation

public struct ProfileDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profiles: [ProxyProfile]
    public var selectedProfileID: UUID?

    public init(profiles: [ProxyProfile] = [], selectedProfileID: UUID? = nil) {
        self.schemaVersion = 1
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
    }
}

public enum ProfileStoreError: Error, CustomStringConvertible {
    case profileNotFound(UUID)
    case duplicateName(String)
    case storageFailure(String)
    case secretFailure(String)

    public var description: String {
        switch self {
        case .profileNotFound(let id):   return "No proxy profile with id \(id.uuidString)."
        case .duplicateName(let name):   return "A proxy called \"\(name)\" already exists."
        case .storageFailure(let detail):return "Could not save the proxy list: \(detail)"
        case .secretFailure(let detail): return "Could not write to the Keychain: \(detail)"
        }
    }
}

public final class ProfileStore {

    public private(set) var document: ProfileDocument
    private let fileURL: URL
    private let secrets: SecretStoring
    private let log: DiagnosticLog?
    private let lock = NSLock()

    /// - Parameters:
    ///   - fileURL: location of the JSON document.
    ///   - secrets: where passwords live.
    public init(fileURL: URL, secrets: SecretStoring = SecretStoreProvider.current, log: DiagnosticLog? = nil) {
        self.fileURL = fileURL
        self.secrets = secrets
        self.log = log
        self.document = ProfileDocument()
        load()
    }

    /// The store used by the app: `Application Support/ProxyTunnel/profiles.json`.
    public static func makeDefault(secrets: SecretStoring = SecretStoreProvider.current, log: DiagnosticLog? = nil) -> ProfileStore {
        let directory = defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"), secrets: secrets, log: log)
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ProxyTunnel", isDirectory: true)
    }

    // MARK: - Reading

    public var profiles: [ProxyProfile] { document.profiles }
    public var selectedProfileID: UUID? { document.selectedProfileID }

    public var selectedProfile: ProxyProfile? {
        guard let id = document.selectedProfileID else { return nil }
        return document.profiles.first { $0.id == id }
    }

    public func profile(id: UUID) -> ProxyProfile? {
        document.profiles.first { $0.id == id }
    }

    /// Profiles that can actually be connected to, in creation order.
    public var enabledProfiles: [ProxyProfile] {
        document.profiles.filter { $0.isEnabled }
    }

    // MARK: - Mutation

    @discardableResult
    public func add(_ draft: ValidatedProxyInput) throws -> ProxyProfile {
        let id = UUID()
        let reference = draft.password != nil ? ProxyProfile.makePasswordReference(for: id) : nil

        let profile = ProxyProfile(
            id: id,
            name: draft.name,
            host: draft.host,
            port: draft.port,
            protocolType: draft.protocolType,
            username: draft.username,
            passwordReference: reference,
            isEnabled: true,
            isMock: draft.isMock,
            notes: draft.notes
        )

        if let password = draft.password, let reference {
            do {
                try secrets.setSecret(password, for: reference)
            } catch {
                throw ProfileStoreError.secretFailure("\(error)")
            }
        }

        lock.lock()
        document.profiles.append(profile)
        if document.selectedProfileID == nil { document.selectedProfileID = id }
        let snapshot = document
        lock.unlock()

        try persist(snapshot)
        log?.info("store", "added proxy: \(profile.redactedSummary)")
        return profile
    }

    /// Updates an existing profile.
    ///
    /// - Parameter password: `.none` leaves the stored password alone; `.some(nil)`
    ///   deletes it; `.some(value)` replaces it.
    public func update(_ profile: ProxyProfile, password: String?? ) throws {
        lock.lock()
        guard let index = document.profiles.firstIndex(where: { $0.id == profile.id }) else {
            lock.unlock()
            throw ProfileStoreError.profileNotFound(profile.id)
        }

        var updated = profile
        updated.updatedAt = Date()

        switch password {
        case .none:
            // Keep whatever reference the stored profile has.
            updated.passwordReference = document.profiles[index].passwordReference
        case .some(.none):
            if let reference = document.profiles[index].passwordReference {
                try? secrets.deleteSecret(for: reference)
            }
            updated.passwordReference = nil
        case .some(.some(let value)):
            let reference = document.profiles[index].passwordReference
                ?? ProxyProfile.makePasswordReference(for: profile.id)
            do {
                try secrets.setSecret(value, for: reference)
            } catch {
                lock.unlock()
                throw ProfileStoreError.secretFailure("\(error)")
            }
            updated.passwordReference = reference
        }

        document.profiles[index] = updated
        let snapshot = document
        lock.unlock()

        try persist(snapshot)
        log?.info("store", "updated proxy: \(updated.redactedSummary)")
    }

    public func delete(id: UUID) throws {
        lock.lock()
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            throw ProfileStoreError.profileNotFound(id)
        }
        let removed = document.profiles.remove(at: index)
        if let reference = removed.passwordReference {
            try? secrets.deleteSecret(for: reference)
        }
        if document.selectedProfileID == id {
            document.selectedProfileID = document.profiles.first?.id
        }
        let snapshot = document
        lock.unlock()

        try persist(snapshot)
        log?.info("store", "deleted proxy \(removed.id.uuidString.prefix(8))…")
    }

    public func deleteAll() throws {
        lock.lock()
        for profile in document.profiles {
            if let reference = profile.passwordReference {
                try? secrets.deleteSecret(for: reference)
            }
        }
        document = ProfileDocument()
        lock.unlock()
        try persist(document)
    }

    public func select(id: UUID?) throws {
        lock.lock()
        if let id, !document.profiles.contains(where: { $0.id == id }) {
            lock.unlock()
            throw ProfileStoreError.profileNotFound(id)
        }
        document.selectedProfileID = id
        let snapshot = document
        lock.unlock()
        try persist(snapshot)
    }

    public func setEnabled(_ enabled: Bool, for id: UUID) throws {
        lock.lock()
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            throw ProfileStoreError.profileNotFound(id)
        }
        document.profiles[index].isEnabled = enabled
        document.profiles[index].updatedAt = Date()
        let snapshot = document
        lock.unlock()
        try persist(snapshot)
    }

    // MARK: - Secrets

    /// Reads the password for a profile, or `nil` when there is none.
    public func password(for profile: ProxyProfile) throws -> String? {
        guard let reference = profile.passwordReference else { return nil }
        return try secrets.secret(for: reference)
    }

    /// Builds the credential for a profile, returning `nil` when the profile
    /// needs no authentication.
    public func credential(for profile: ProxyProfile) throws -> ProxyCredential? {
        guard let username = profile.username, !username.isEmpty else { return nil }
        let password = try password(for: profile) ?? ""
        return ProxyCredential(username: username, password: password)
    }

    /// True when a profile claims to have a password but the Keychain no longer
    /// has one — typically after a restore to a new device, because the items are
    /// stored `ThisDeviceOnly`.
    public func isMissingStoredPassword(for profile: ProxyProfile) -> Bool {
        guard profile.passwordReference != nil else { return false }
        return (try? secrets.secret(for: profile.passwordReference!)) == nil
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            document = ProfileDocument()
            return
        }
        do {
            document = try JSONDecoder().decode(ProfileDocument.self, from: data)
            log?.info("store", "loaded \(document.profiles.count) proxy profile(s)")
        } catch {
            // Never destroy user data on a decode failure: keep the file, start
            // empty, and say so.
            log?.error("store", "could not decode \(fileURL.lastPathComponent): \(error). Keeping the file untouched.")
            document = ProfileDocument()
        }
    }

    private func persist(_ snapshot: ProfileDocument) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // `.completeFileProtection` keeps the file encrypted at rest while the
            // device is locked. It contains no secrets, but the proxy list is
            // still nobody else's business.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw ProfileStoreError.storageFailure("\(error)")
        }
    }
}
