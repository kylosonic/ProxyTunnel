//
//  ExtensionLogMirror.swift
//  ProxyTunnelExtension
//
//  The extension's `DiagnosticLog` lives in the extension process, which the app
//  cannot read. When an App Group container exists we mirror the text log into it
//  periodically so the Logs screen can offer it; otherwise the extension's log is
//  only reachable through Console.app, and the Diagnostics counters in the status
//  payload are the only in-app evidence.
//
//  Mirroring is throttled: writing on every line would be a lot of flash I/O for
//  no benefit.
//

import Foundation
import ProxyTunnelCore

final class ExtensionLogMirror {

    private let log: DiagnosticLog
    private var flushTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.github.kylosonic.proxytunnel.logmirror", qos: .utility)
    private var lastWrittenByteCount = 0

    init(log: DiagnosticLog) {
        self.log = log
    }

    func start() {
        guard SharedContainer.isAvailable else {
            log.info("log", "App Group container unavailable; the extension log will not be visible in the app")
            return
        }
        // A one-off header makes it obvious in the shared file which run it came
        // from.
        SharedContainer.clearExtensionLog()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.writeIfChanged()
        }
        timer.resume()
        flushTimer = timer
    }

    func flush() {
        writeIfChanged()
    }

    private func writeIfChanged() {
        let text = log.exportText()
        // `exportText()` is cheap but not free; skip identical writes.
        guard text.utf8.count != lastWrittenByteCount else { return }
        lastWrittenByteCount = text.utf8.count
        SharedContainer.writeExtensionLog(text)
    }

    deinit {
        flushTimer?.cancel()
    }
}
