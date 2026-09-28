//
//  ProxyExportView.swift
//  ProxyTunnel
//
//  Move a saved proxy into an app that can actually run a tunnel.
//
//  This screen exists because of a specific, documented limitation: on a build
//  whose signature lacks the Network Extension entitlement, ProxyTunnel cannot
//  route traffic, but plenty of App Store proxy clients can — their developers
//  hold the entitlement. Handing the proxy over in a shape they accept is the most
//  useful thing this build can do, so the screen says that plainly rather than
//  pretending the export is a convenience.
//

import SwiftUI
import UIKit
import ProxyTunnelCore

struct ProxyExportView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let profile: ProxyProfile

    @State private var format: ProxyExportFormat = .shareLink
    @State private var includePassword = true
    @State private var exported: String = ""
    @State private var loadError: String?
    @State private var hasCopied = false

    var body: some View {
        NavigationStack {
            Form {
                explanationSection
                formatSection
                textSection
                actionSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundGradient)
            .navigationTitle("Export proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { rebuild() }
            .onChange(of: format) { _ in rebuild() }
            .onChange(of: includePassword) { _ in rebuild() }
        }
    }

    // MARK: Why

    private var explanationSection: some View {
        Section {
            NoticeBanner(
                level: .info,
                title: "This build can't run the tunnel — another app can",
                message: """
                ProxyTunnel is signed without the Network Extension entitlement, so iOS will not let it route your traffic. Proxy clients on the App Store hold that entitlement, so the practical route is to paste this proxy into one of them: Hiddify (free), Shadowrocket, sing-box, Stash and similar all accept a socks5:// share link.
                """
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        } header: {
            Text("What this is for")
        }
    }

    // MARK: Format

    private var formatSection: some View {
        Section {
            Picker("Format", selection: $format) {
                ForEach(ProxyExportFormat.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Text(format.subtitle)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Include the password", isOn: $includePassword)

            if includePassword {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                    Text("""
                    The text below contains your password in plain sight, and copying it puts the password on the system clipboard, where other apps and clipboard-history features can read it. Turn this off to share the shape of the proxy without the secret.
                    """)
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Format")
        } footer: {
            Text("A complete client configuration is deliberately not generated: its schema differs between sing-box versions and between the apps that embed it, so a generated one would look authoritative and be wrong for somebody's version. The outbound block and the share link have stayed stable.")
        }
    }

    // MARK: Text

    private var textSection: some View {
        Section {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(exported)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                }
                .frame(maxHeight: 220)
            }
        } header: {
            Text("Exported")
        }
    }

    // MARK: Actions

    private var actionSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = exported
                hasCopied = true
                environment.log.info(
                    "export",
                    "copied \(format.rawValue) for \(profile.redactedSummary) (password included: \(includePassword))"
                )
            } label: {
                Label(hasCopied ? "Copied" : "Copy to clipboard", systemImage: hasCopied ? "checkmark" : "doc.on.doc")
            }
            .disabled(exported.isEmpty || loadError != nil)

            if !exported.isEmpty {
                ShareLink(item: exported) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Use it")
        } footer: {
            Text("""
            In your proxy client, look for "Add", "Import" or "Add configuration from clipboard", and paste. If it only offers a form, use the Plain fields format and type the values in.

            Nothing about this export is logged: your password never reaches the app's log.
            """)
        }
    }

    // MARK: Logic

    private func rebuild() {
        hasCopied = false
        loadError = nil

        let credential: ProxyCredential?
        do {
            credential = try environment.profileStore.credential(for: profile)
        } catch {
            credential = nil
            loadError = "Could not read the stored password: \(error)"
            environment.log.error("export", "could not read the credential for export: \(error)")
        }

        if credential == nil, profile.usesAuthentication {
            loadError = "This profile has a username but no password in the Keychain, so an export would not work. Re-enter the password in the proxy's settings."
        }

        exported = ProxyExportFormatter.text(
            for: profile,
            credential: credential,
            format: format,
            options: ProxyExportOptions(includePassword: includePassword)
        )
    }
}
