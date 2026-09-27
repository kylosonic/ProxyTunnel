//
//  ProxyListView.swift
//  ProxyTunnel
//

import SwiftUI
import ProxyTunnelCore

struct ProxyListView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @State private var editingProfile: ProxyProfile?
    @State private var isAddingNew = false
    @State private var pendingDeletion: ProxyProfile?

    var body: some View {
        NavigationStack {
            Group {
                if environment.profileStore.profiles.isEmpty {
                    EmptyStateView(
                        symbol: "server.rack",
                        title: "No proxies yet",
                        message: "Add a proxy using the host, port, protocol and credentials your provider gave you.",
                        actionTitle: "Add proxy",
                        action: { isAddingNew = true }
                    )
                } else {
                    list
                }
            }
            .appBackground()
            .navigationTitle("Proxies")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isAddingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add proxy")
                }
            }
            .sheet(isPresented: $isAddingNew) {
                ProxyEditView(mode: .create)
                    .environmentObject(environment)
            }
            .sheet(item: $editingProfile) { profile in
                ProxyEditView(mode: .edit(profile))
                    .environmentObject(environment)
            }
            .confirmationDialog(
                "Delete \(pendingDeletion?.name ?? "this proxy")?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let profile = pendingDeletion {
                        delete(profile)
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("The stored password for this proxy is deleted from the Keychain as well.")
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(environment.profileStore.profiles) { profile in
                    row(profile)
                }
                notices
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private func row(_ profile: ProxyProfile) -> some View {
        let isSelected = environment.profileStore.selectedProfileID == profile.id
        let missingPassword = environment.profileStore.isMissingStoredPassword(for: profile)

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(profile.name)
                                .font(.headline)
                                .foregroundStyle(Theme.primaryText)
                            if profile.isMock {
                                Text("MOCK")
                                    .font(.caption2.weight(.black))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.mock.opacity(0.2)))
                                    .foregroundStyle(Theme.mock)
                            }
                            if !profile.isEnabled {
                                Text("DISABLED")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                        Text(profile.displayEndpoint)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        ProtocolBadge(protocolType: profile.protocolType)
                        if isSelected {
                            Label("Selected", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.success)
                        }
                    }
                }

                if missingPassword {
                    Label(
                        "A password was saved for this proxy but the Keychain item is gone (this happens after restoring to a new device). Re-enter it.",
                        systemImage: "key.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        try? environment.profileStore.select(id: profile.id)
                    } label: {
                        Label(isSelected ? "Selected" : "Select", systemImage: isSelected ? "checkmark.circle" : "circle")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSelected)

                    Button {
                        editingProfile = profile
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Menu {
                        Toggle("Enabled", isOn: Binding(
                            get: { profile.isEnabled },
                            set: { try? environment.profileStore.setEnabled($0, for: profile.id) }
                        ))
                        Button(role: .destructive) {
                            pendingDeletion = profile
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? Theme.success.opacity(0.4) : Theme.hairline, lineWidth: 1)
        )
    }

    private var notices: some View {
        VStack(spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Where your password is kept", systemImage: "key.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Proxy passwords are stored in the iOS Keychain, never in this app's files and never in the VPN configuration when a shared container is available.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !SharedContainer.isAvailable {
                NoticeBanner(
                    level: .warning,
                    title: "Shared container unavailable",
                    message: SharedContainer.statusDescription
                )
            }
        }
    }

    private func delete(_ profile: ProxyProfile) {
        do {
            try environment.profileStore.delete(id: profile.id)
        } catch {
            environment.log.error("store", "could not delete profile: \(error)")
        }
    }
}
