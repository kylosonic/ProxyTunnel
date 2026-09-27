//
//  ProxyEditView.swift
//  ProxyTunnel
//
//  The add/edit form.
//
//  Two things this screen does that a lot of proxy editors do not:
//
//   * it shows *all* validation problems at once, so the user is not walked
//     through them one failed Save at a time;
//   * it offers a real connectivity test that opens the proxy and fetches a page
//     through it, and reports the proxy's egress IP. That is the only way to know
//     a profile is correct when the Network Extension itself cannot run.
//

import SwiftUI
import ProxyTunnelCore

struct ProxyEditView: View {

    enum Mode: Equatable {
        case create
        case edit(ProxyProfile)

        var title: String {
            switch self {
            case .create: return "Add proxy"
            case .edit:   return "Edit proxy"
            }
        }
    }

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var draft: ProxyProfileDraft
    @State private var report = ValidationReport()
    @State private var showPassword = false
    @State private var probeState: ProbeState = .idle
    @State private var isTesting = false
    @State private var saveError: String?

    private enum ProbeState {
        case idle
        case running
        case finished(ProxyProbeReport)
        case failed(String)
    }

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _draft = State(initialValue: ProxyProfileDraft())
        case .edit(let profile):
            _draft = State(initialValue: ProxyProfileDraft(profile: profile))
        }
    }

    private var existingProfile: ProxyProfile? {
        if case .edit(let profile) = mode { return profile }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.words)
                    fieldIssue(.name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("A label for this proxy, for example \u{201C}ProxyCheap — Frankfurt\u{201D}.")
                }

                Section {
                    TextField("Host or IP address", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    fieldIssue(.host)

                    TextField("Port", text: $draft.portText)
                        .keyboardType(.numberPad)
                    fieldIssue(.port)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Enter the host on its own. Do not include a scheme such as socks5:// or a trailing \":port\".")
                }

                Section {
                    Picker("Protocol", selection: $draft.protocolType) {
                        ForEach(ProxyProtocol.allCases) { protocolType in
                            Text(protocolType.displayName).tag(protocolType)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(draft.protocolType.shortDescription)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)

                    CapabilityTable(protocolType: draft.protocolType)
                } header: {
                    Text("Protocol")
                }

                Section {
                    TextField("Username", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    fieldIssue(.username)

                    HStack {
                        if showPassword {
                            TextField(passwordPlaceholder, text: $draft.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField(passwordPlaceholder, text: $draft.password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondaryText)
                    }
                    fieldIssue(.password)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text(existingProfile == nil
                         ? "Leave both blank if your proxy needs no authentication. The password is written to the iOS Keychain."
                         : "Leave the password blank to keep the password already stored in the Keychain.")
                }

                Section {
                    TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...5)
                    fieldIssue(.notes)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Notes are stored in plain text on this device. Do not put passwords here.")
                }

                Section {
                    Toggle("Development / mock profile", isOn: $draft.isMock)
                } footer: {
                    Text("Marks this profile as a placeholder for UI testing. Mock profiles are labelled everywhere and never claim to route traffic.")
                }

                probeSection

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundGradient)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save", action: save).bold()
                }
            }
            .onChange(of: draft.protocolType) { _ in
                // Offer the conventional port when the protocol changes and the
                // field is still untouched.
                if draft.portText.isEmpty || ProxyProtocol.allCases.map({ String($0.defaultPort) }).contains(draft.portText) {
                    draft.portText = String(draft.protocolType.defaultPort)
                }
                revalidate()
            }
            .onChange(of: draft.host) { _ in revalidate() }
            .onChange(of: draft.portText) { _ in revalidate() }
            .onChange(of: draft.username) { _ in revalidate() }
            .onChange(of: draft.password) { _ in revalidate() }
            .onAppear {
                if draft.portText.isEmpty {
                    draft.portText = String(draft.protocolType.defaultPort)
                }
                if case .edit(let profile) = mode, profile.username != nil, existingProfile?.passwordReference != nil {
                    // Load the stored password so the user can see that one exists
                    // without it being displayed.
                    if let stored = try? environment.profileStore.password(for: profile) {
                        draft.password = stored ?? ""
                    }
                }
                revalidate()
            }
        }
    }

    private var passwordPlaceholder: String {
        existingProfile?.passwordReference != nil && draft.password.isEmpty ? "•••••• (saved)" : "Password"
    }

    @ViewBuilder
    private func fieldIssue(_ field: ValidationIssue.Field) -> some View {
        let issues = report.issues(for: field)
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: issue.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(issue.severity == .error ? Theme.danger : Theme.warning)
                        Text(issue.message)
                            .font(.caption)
                            .foregroundStyle(issue.severity == .error ? Theme.danger : Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Probe

    @ViewBuilder
    private var probeSection: some View {
        Section {
            Button {
                runProbe()
            } label: {
                HStack {
                    Label("Test connection", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isTesting || !report.isValid)

            switch probeState {
            case .idle:
                Text("Opens the proxy, requests a page through it and reports the IP address the far end saw. This does not use the VPN tunnel, so it works even when the tunnel cannot start.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)

            case .running:
                Text("Connecting…")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)

            case .finished(let probe):
                ProbeReportView(report: probe)

            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }
        } header: {
            Text("Verify")
        }
    }

    private func runProbe() {
        let (result, input) = ProxyProfileValidator.validate(draft)
        report = result
        guard let input else { return }

        isTesting = true
        probeState = .running

        let credential: ProxyCredential?
        if let username = input.username, let password = input.password {
            credential = ProxyCredential(username: username, password: password)
        } else if let username = input.username, let existing = existingProfile,
                  let stored = try? environment.profileStore.password(for: existing) {
            credential = ProxyCredential(username: username, password: stored ?? "")
        } else {
            credential = nil
        }

        let endpoint = ProxyEndpoint(
            host: input.host,
            port: input.port,
            protocolType: input.protocolType,
            credential: credential
        )
        var probeConfiguration = ProxyProbeConfiguration.default
        probeConfiguration.checkHost = environment.settings.probeHost
        probeConfiguration.checkPath = environment.settings.probePath

        environment.log.info("probe", "starting connectivity test against \(endpoint.redactedEndpoint)")

        Task {
            let probe = await ProxyProbe.run(
                endpoint: endpoint,
                configuration: probeConfiguration,
                log: environment.log
            )
            await MainActor.run {
                probeState = .finished(probe)
                isTesting = false
            }
        }
    }

    // MARK: Save

    private func revalidate() {
        report = ProxyProfileValidator.validate(draft).report
    }

    private func save() {
        let (result, input) = ProxyProfileValidator.validate(draft)
        report = result

        guard let input else {
            saveError = "Fix the \(result.errors.count) problem\(result.errors.count == 1 ? "" : "s") highlighted above."
            return
        }
        saveError = nil

        do {
            switch mode {
            case .create:
                try environment.profileStore.add(input)

            case .edit(let profile):
                var updated = profile
                updated.name = input.name
                updated.host = input.host
                updated.port = input.port
                updated.protocolType = input.protocolType
                updated.username = input.username
                updated.notes = input.notes
                updated.isMock = input.isMock

                // A blank password field on an existing profile means "keep the
                // stored one"; an empty username means "no credentials".
                let passwordUpdate: String??
                if input.username == nil {
                    passwordUpdate = .some(nil)
                } else if let password = input.password {
                    passwordUpdate = .some(.some(password))
                } else {
                    passwordUpdate = .none
                }
                try environment.profileStore.update(updated, password: passwordUpdate)
            }
            dismiss()
        } catch {
            saveError = "\(error)"
            environment.log.error("store", "could not save the proxy: \(error)")
        }
    }
}

// MARK: - Capability table

struct CapabilityTable: View {
    let protocolType: ProxyProtocol

    private var capabilities: ProxyProtocolCapabilities {
        ProxyProtocolCapabilities.describe(protocolType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("TCP", capabilities.tcp, ok: true)
            row("UDP", capabilities.udp, ok: protocolType.supportsUDP)
            row("DNS", capabilities.dns, ok: true)
            row("IPv4", capabilities.ipv4, ok: true)
            row("IPv6", capabilities.ipv6, ok: true)
            ForEach(capabilities.notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func row(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 38, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(ok ? Theme.secondaryText : Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Probe report

struct ProbeReportView: View {

    let report: ProxyProbeReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: report.isSuccess ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(report.isSuccess ? Theme.success : Theme.danger)
                Text(report.isSuccess ? "The proxy relayed traffic" : "The test did not complete")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(report.isSuccess ? Theme.success : Theme.danger)
            }

            ForEach(report.summaryLines, id: \.self) { line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(String(format: "Total %.1f s", report.totalDuration))
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
        }
    }
}
