//
//  LogsView.swift
//  ProxyTunnel
//

import SwiftUI
import UIKit
import ProxyTunnelCore

struct LogsView: View {

    @EnvironmentObject private var environment: AppEnvironment

    @State private var entries: [DiagnosticEntry] = []
    @State private var minimumLevel: DiagnosticEntry.Level = .debug
    @State private var extensionLog: String?
    @State private var showExtensionLog = false
    @State private var observerToken: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Level", selection: $minimumLevel) {
                ForEach(DiagnosticEntry.Level.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Toggle("Show the extension's log instead", isOn: $showExtensionLog)
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .onChange(of: showExtensionLog) { _ in reloadExtensionLog() }

            if showExtensionLog {
                extensionLogSection
            } else {
                appLogSection
            }
        }
        .appBackground()
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = exportText()
                    } label: {
                        Label("Copy all", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: exportText()) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        environment.log.clear()
                        SharedContainer.clearExtensionLog()
                        refresh()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            refresh()
            observerToken = environment.log.addObserver { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear {
            if let observerToken {
                environment.log.removeObserver(observerToken)
            }
            observerToken = nil
        }
        .onChange(of: minimumLevel) { _ in refresh() }
    }

    private var appLogSection: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    symbol: "doc.text",
                    title: "No log entries",
                    message: "Nothing has been logged at this level yet."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(Theme.tertiaryText)
                                Text(entry.level.rawValue.uppercased())
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 52, alignment: .leading)
                                Text("[\(entry.category)]")
                                    .foregroundStyle(Theme.tertiaryText)
                                Text(entry.message)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                    .textSelection(.enabled)
                }
            }
        }
    }

    private var extensionLogSection: some View {
        Group {
            if let extensionLog, !extensionLog.isEmpty {
                ScrollView {
                    Text(extensionLog)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .textSelection(.enabled)
                }
            } else {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass",
                    title: "No extension log",
                    message: SharedContainer.isAvailable
                        ? "The extension has not written a log yet. It only runs while the tunnel is up."
                        : "The App Group container is unavailable, so the extension cannot mirror its log here. Use Console.app on a Mac, or the in-app Diagnostics counters, instead."
                )
            }
        }
    }

    private func color(for level: DiagnosticEntry.Level) -> Color {
        switch level {
        case .trace, .debug: return Theme.tertiaryText
        case .info:          return Theme.accent
        case .warning:       return Theme.warning
        case .error:         return Theme.danger
        }
    }

    private func refresh() {
        entries = environment.log.snapshot(minimumLevel: minimumLevel)
        if showExtensionLog { reloadExtensionLog() }
    }

    private func reloadExtensionLog() {
        extensionLog = SharedContainer.readExtensionLog()
    }

    private func exportText() -> String {
        var text = environment.log.exportText()
        text += "\n\n# Build\n"
        text += "# app \(AppVersion.displayString) (\(AppVersion.bundleIdentifier))\n"
        text += "# extension \(AppVersion.extensionBundleIdentifier)\n"
        text += "# app group available: \(SharedContainer.isAvailable)\n"
        text += "# packet tunnel entitlement present: \(environment.entitlements.extensionHasPacketTunnelEntitlement)\n"
        if let extensionLog, !extensionLog.isEmpty {
            text += "\n\n# Extension log\n\(extensionLog)\n"
        }
        return text
    }
}
