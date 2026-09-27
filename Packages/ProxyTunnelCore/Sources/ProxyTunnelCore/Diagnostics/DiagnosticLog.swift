//
//  DiagnosticLog.swift
//  ProxyTunnelCore
//
//  The app's log. Everything that is written here has already been through
//  `LogRedactor`, and the ring buffer is bounded so a runaway tunnel cannot
//  exhaust memory.
//
//  This deliberately does NOT use `os.Logger` as the primary sink: unified
//  logging is not readable from inside the app, and the Diagnostics screen needs
//  to show the user what happened. `os.Logger` is used as a *secondary* sink so
//  that `log stream` / Console.app still works during development — with
//  `privacy: .private` so values are redacted there too.
//

import Foundation
import os

public struct DiagnosticEntry: Identifiable, Equatable, Sendable {

    public enum Level: String, Sendable, CaseIterable {
        case trace, debug, info, warning, error

        public var symbol: String {
            switch self {
            case .trace:   return "·"
            case .debug:   return "◦"
            case .info:    return "i"
            case .warning: return "!"
            case .error:   return "×"
            }
        }

        var osLogType: OSLogType {
            switch self {
            case .trace, .debug: return .debug
            case .info:          return .info
            case .warning:       return .default
            case .error:         return .error
            }
        }
    }

    public let id: UUID
    public let timestamp: Date
    public let level: Level
    public let category: String
    public let message: String

    public init(timestamp: Date = Date(), level: Level, category: String, message: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }

    /// `<time> <LEVEL> [<category>] <message>` — one line, no secrets.
    public func formatted(using formatter: DateFormatter) -> String {
        "\(formatter.string(from: timestamp)) \(level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)) [\(category)] \(message)"
    }
}

/// A bounded, thread-safe, redacting log.
public final class DiagnosticLog {

    /// Anything that should be told "the log changed" (the SwiftUI Logs screen).
    public typealias Observer = (DiagnosticEntry) -> Void

    private let capacity: Int
    private let subsystem: String
    private var entries: [DiagnosticEntry] = []
    private let lock = NSLock()
    private var observers: [UUID: Observer] = [:]
    private let osLog: Logger

    /// Set to `false` in tests where the log noise is not useful.
    public var minimumLevel: DiagnosticEntry.Level = .trace

    public init(subsystem: String = AppIdentifiers.mainAppBundleIdentifier, capacity: Int = 2_000) {
        self.subsystem = subsystem
        self.capacity = max(64, capacity)
        self.osLog = Logger(subsystem: subsystem, category: "ProxyTunnel")
        self.entries.reserveCapacity(self.capacity)
    }

    // MARK: Writing

    public func log(_ level: DiagnosticEntry.Level, _ category: String, _ message: @autoclosure () -> String) {
        guard level.rank >= minimumLevel.rank else { return }
        // Redact *before* anything is stored or handed to os_log.
        let safeMessage = LogRedactor.redact(message())
        let entry = DiagnosticEntry(level: level, category: category, message: safeMessage)

        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        let snapshot = Array(observers.values)
        lock.unlock()

        osLog.log(level: level.osLogType, "[\(category, privacy: .public)] \(safeMessage, privacy: .private)")

        for observer in snapshot { observer(entry) }
    }

    public func trace(_ category: String, _ message: @autoclosure () -> String) { log(.trace, category, message()) }
    public func debug(_ category: String, _ message: @autoclosure () -> String) { log(.debug, category, message()) }
    public func info(_ category: String, _ message: @autoclosure () -> String) { log(.info, category, message()) }
    public func warning(_ category: String, _ message: @autoclosure () -> String) { log(.warning, category, message()) }
    public func error(_ category: String, _ message: @autoclosure () -> String) { log(.error, category, message()) }

    public func log(_ failure: TunnelFailure) {
        log(.error, "failure", failure.diagnosticLine)
    }

    // MARK: Reading

    public func snapshot(minimumLevel: DiagnosticEntry.Level = .trace) -> [DiagnosticEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.level.rank >= minimumLevel.rank }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
    }

    /// The full log as text, ready to be shared as a bug report attachment.
    public func exportText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let rows = snapshot()
        var out = "# ProxyTunnel diagnostic log\n"
        out += "# generated \(formatter.string(from: Date()))\n"
        out += "# \(rows.count) entries. Credentials are redacted at write time.\n"
        for entry in rows {
            out += entry.formatted(using: formatter)
            out += "\n"
        }
        return out
    }

    // MARK: Observation

    @discardableResult
    public func addObserver(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        lock.lock(); observers[token] = observer; lock.unlock()
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock(); observers.removeValue(forKey: token); lock.unlock()
    }

    // MARK: Shared instance

    /// The log used by the main app.
    public static let shared = DiagnosticLog()

    /// A separate instance for the extension process so the two are easy to tell
    /// apart in Console.app. The extension mirrors it to disk (see
    /// `LogFileMirror`) so the app can display extension logs too.
    public static let extensionLog = DiagnosticLog(
        subsystem: AppIdentifiers.mainAppBundleIdentifier + ".tunnel",
        capacity: 4_000
    )
}

extension DiagnosticEntry.Level {
    var rank: Int {
        switch self {
        case .trace:   return 0
        case .debug:   return 1
        case .info:    return 2
        case .warning: return 3
        case .error:   return 4
        }
    }
}
