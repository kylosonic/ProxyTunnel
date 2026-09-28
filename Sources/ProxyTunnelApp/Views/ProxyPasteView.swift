//
//  ProxyPasteView.swift
//  ProxyTunnel
//
//  Paste a proxy — or a whole list of them — in whatever format the provider
//  handed you.
//
//  The screen is built around one idea: show what was understood *before*
//  anything is saved. Every line gets a verdict, the reading that was chosen is
//  spelled out, and anything ambiguous says so. Nothing is written to the
//  Keychain until the user taps Add.
//

import SwiftUI
import UIKit
import ProxyTunnelCore

struct ProxyPasteView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var protocolSelection: ProtocolChoice = .auto
    @State private var namePrefix: String = ""
    @State private var skipDuplicates = true
    @State private var report = ProxyImportReport(entries: [])
    @State private var addSummary: AddSummary?

    private struct AddSummary {
        var added: Int
        var skipped: Int
        var failed: [String]
    }

    /// What the protocol picker offers. `auto` lets the pasted text decide, and
    /// falls back to inferring from the port.
    private enum ProtocolChoice: String, CaseIterable, Identifiable {
        case auto
        case socks5
        case httpConnect
        case httpsConnect

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto:         return "Auto"
            case .socks5:       return "SOCKS5"
            case .httpConnect:  return "HTTP"
            case .httpsConnect: return "HTTPS"
            }
        }

        var proxyProtocol: ProxyProtocol? {
            switch self {
            case .auto:         return nil
            case .socks5:       return .socks5
            case .httpConnect:  return .httpConnect
            case .httpsConnect: return .httpsConnect
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                pasteSection
                optionsSection
                previewSection
                if let addSummary { resultSection(addSummary) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundGradient)
            .navigationTitle("Paste proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(addButtonTitle) { addAll() }
                        .bold()
                        .disabled(report.ready.isEmpty)
                }
            }
            .onAppear { recompute() }
        }
    }

    private var addButtonTitle: String {
        report.ready.isEmpty ? "Add" : "Add \(report.ready.count)"
    }

    // MARK: Paste

    private var pasteSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("""
                    Paste one proxy per line. Any of these work:

                    socks5://user:pass@host:1080
                    host:1080:user:pass
                    user:pass@host:1080
                    host:1080
                    {"host":"…","port":1080,…}
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 130)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: text) { _ in recompute() }
            }

            HStack(spacing: 12) {
                Button {
                    if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                        text = clipboard
                        recompute()
                    }
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)

                if !text.isEmpty {
                    Button(role: .destructive) {
                        text = ""
                        addSummary = nil
                        recompute()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Paste")
        } footer: {
            Text("Passwords you paste are written straight to the iOS Keychain when you tap Add. They are masked everywhere on this screen and are never written to the app's logs.")
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        Section {
            Picker("Protocol", selection: $protocolSelection) {
                ForEach(ProtocolChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: protocolSelection) { _ in recompute() }

            TextField("Name prefix (optional)", text: $namePrefix)
                .textInputAutocapitalization(.words)
                .onChange(of: namePrefix) { _ in recompute() }

            Toggle("Skip proxies I already have", isOn: $skipDuplicates)
                .onChange(of: skipDuplicates) { _ in recompute() }
        } header: {
            Text("Options")
        } footer: {
            Text("Set **Auto** to take the protocol from the pasted text — a `socks5://` link, a `protocol=…` field, a JSON `protocol` key — and otherwise infer it from the port. Choosing a protocol here overrides anything the text does not state.")
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewSection: some View {
        Section {
            if report.entries.isEmpty {
                Text("Nothing pasted yet.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                HStack {
                    Text(report.summary)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(report.hasProblems ? Theme.warning : Theme.success)
                    Spacer()
                }

                ForEach(report.entries) { entry in
                    entryRow(entry)
                }
            }
        } header: {
            Text("What was understood")
        } footer: {
            if report.entries.isEmpty {
                Text("Every line is checked as you paste. Nothing is saved until you tap Add.")
            } else {
                Text("Anything marked amber was read one way where the text allowed two; check the host after adding and edit it if the reading was wrong.")
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: ProxyImportEntry) -> some View {
        if let candidate = entry.candidate {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                    if let name = candidate.name {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                    }
                    Text(candidate.displayEndpoint)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    ProtocolBadge(protocolType: candidate.protocolType)
                }

                HStack(spacing: 10) {
                    if let username = candidate.username {
                        Label(username, systemImage: "person")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        Label("no authentication", systemImage: "person.slash")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    if candidate.password != nil {
                        Label("password saved on Add", systemImage: "key.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if skipDuplicates, isDuplicate(candidate) {
                        Label("already added — will skip", systemImage: "equal.circle")
                            .font(.caption2)
                            .foregroundStyle(Theme.warning)
                    }
                }

                ForEach(candidate.notes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: candidate.isAmbiguous ? "exclamationmark.triangle.fill" : "info.circle")
                            .font(.caption2)
                            .foregroundStyle(candidate.isAmbiguous ? Theme.warning : Theme.tertiaryText)
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(candidate.isAmbiguous ? Theme.warning : Theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)

        } else if let failure = entry.failure {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.isIgnorable ? "minus.circle" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(entry.isIgnorable ? Theme.tertiaryText : Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.redactedSource.isEmpty ? "(blank line)" : entry.redactedSource)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                    Text(failure.message)
                        .font(.caption2)
                        .foregroundStyle(entry.isIgnorable ? Theme.tertiaryText : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Result

    @ViewBuilder
    private func resultSection(_ summary: AddSummary) -> some View {
        Section {
            if summary.added > 0 {
                Label(
                    "Added \(summary.added) prox\(summary.added == 1 ? "y" : "ies").",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.success)
            }
            if summary.skipped > 0 {
                Label("Skipped \(summary.skipped) already present.", systemImage: "equal.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(summary.failed, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Result")
        }
    }

    // MARK: Logic

    private func recompute() {
        addSummary = nil
        report = ProxyImportParser.parse(text, defaultProtocol: protocolSelection.proxyProtocol)
    }

    /// A proxy is "already present" when the same endpoint is configured with the
    /// same protocol — the credentials are irrelevant to that judgement, which is
    /// what makes re-pasting a list after a provider rotates passwords still
    /// adding nothing new.
    private func isDuplicate(_ candidate: ProxyImportCandidate) -> Bool {
        environment.profileStore.profiles.contains { profile in
            profile.host.caseInsensitiveCompare(candidate.host) == .orderedSame
                && profile.port == candidate.port
                && profile.protocolType == candidate.protocolType
        }
    }

    private func addAll() {
        var added = 0
        var skipped = 0
        var failures: [String] = []
        var firstAddedID: UUID?

        for entry in report.ready {
            guard let candidate = entry.candidate else { continue }

            if skipDuplicates, isDuplicate(candidate) {
                skipped += 1
                continue
            }

            let suggestedName = namePrefix.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : "\(namePrefix.trimmingCharacters(in: .whitespaces)) \(candidate.name ?? candidate.displayEndpoint)"

            // The manual form's validator is the authority on what is storable, so
            // a pasted proxy goes through exactly the same gate.
            let (validation, input) = ProxyProfileValidator.validate(candidate.asDraft(suggestedName: suggestedName))
            guard let input else {
                failures.append("\(candidate.displayEndpoint): \(validation.errors.first?.message ?? "did not validate")")
                continue
            }

            do {
                let profile = try environment.profileStore.add(input)
                if firstAddedID == nil { firstAddedID = profile.id }
                added += 1
            } catch {
                failures.append("\(candidate.displayEndpoint): \(error)")
                environment.log.error("import", "could not add a pasted proxy: \(error)")
            }
        }

        if let firstAddedID, environment.profileStore.selectedProfileID == nil {
            try? environment.profileStore.select(id: firstAddedID)
        }

        environment.log.info(
            "import",
            "pasted import: \(added) added, \(skipped) skipped, \(failures.count) failed, \(report.problems.count) unreadable line(s)"
        )
        addSummary = AddSummary(added: added, skipped: skipped, failed: failures)

        if added > 0 {
            text = ""
            report = ProxyImportReport(entries: [])
        }
    }
}
