//
//  PhysicalInterfaceResolver.swift
//  ProxyTunnelExtension
//
//  Finds the real network interface the tunnel's own transport should use.
//
//  ## The loop problem
//
//  Once the tunnel installs a default route, a socket opened inside the extension
//  would, by default, send its packets to the proxy *through the tunnel* — back
//  to itself. Real VPN clients solve this in one of two ways:
//
//    1. exclude the VPN server's addresses from the tunnel routes, and/or
//    2. bind the transport socket to the physical interface.
//
//  We do both. (1) is done in `TunnelNetworkSettingsFactory` using the addresses
//  the app resolved before the tunnel existed. This file provides (2).
//
//  `NWInterface` has no public initialiser, so the only way to obtain one is from
//  an `NWPath`. Monitoring with `requiredInterfaceType` gives us the Wi-Fi
//  interface when Wi-Fi is usable and the cellular interface otherwise, which is
//  exactly the interface we want the proxy connection pinned to.
//

import Foundation
import Network
import ProxyTunnelCore

final class PhysicalInterfaceResolver {

    private let log: DiagnosticLog
    private let queue: DispatchQueue

    private var wifiMonitor: NWPathMonitor?
    private var cellularMonitor: NWPathMonitor?
    private var wiredMonitor: NWPathMonitor?

    private var wifiInterface: NWInterface?
    private var cellularInterface: NWInterface?
    private var wiredInterface: NWInterface?

    init(log: DiagnosticLog, queue: DispatchQueue) {
        self.log = log
        self.queue = queue
    }

    /// The best available physical interface, preferring the cheapest metered
    /// link last: wired > Wi-Fi > cellular.
    ///
    /// Returned as an optional because at start time the monitors may not have
    /// produced a path yet. `nil` simply means "rely on the excluded routes",
    /// which is a correct fallback rather than a broken state.
    var currentInterface: NWInterface? {
        wiredInterface ?? wifiInterface ?? cellularInterface
    }

    var description: String {
        let parts = [
            wiredInterface.map { "wired=\($0.name)" },
            wifiInterface.map { "wifi=\($0.name)" },
            cellularInterface.map { "cellular=\($0.name)" }
        ].compactMap { $0 }
        return parts.isEmpty ? "none detected yet" : parts.joined(separator: " ")
    }

    func start() {
        wifiMonitor = makeMonitor(for: .wifi) { [weak self] interface in
            self?.wifiInterface = interface
        }
        cellularMonitor = makeMonitor(for: .cellular) { [weak self] interface in
            self?.cellularInterface = interface
        }
        wiredMonitor = makeMonitor(for: .wiredEthernet) { [weak self] interface in
            self?.wiredInterface = interface
        }
        log.info("interface", "physical interface resolver started")
    }

    func stop() {
        wifiMonitor?.cancel(); wifiMonitor = nil
        cellularMonitor?.cancel(); cellularMonitor = nil
        wiredMonitor?.cancel(); wiredMonitor = nil
        wifiInterface = nil
        cellularInterface = nil
        wiredInterface = nil
    }

    private func makeMonitor(
        for type: NWInterface.InterfaceType,
        assign: @escaping (NWInterface?) -> Void
    ) -> NWPathMonitor {
        let monitor = NWPathMonitor(requiredInterfaceType: type)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async {
                if path.status == .satisfied {
                    let interface = path.availableInterfaces.first { $0.type == type }
                    assign(interface)
                    if let interface {
                        self.log.debug("interface", "\(type) available as \(interface.name)")
                    }
                } else {
                    assign(nil)
                }
            }
        }
        monitor.start(queue: queue)
        return monitor
    }
}
