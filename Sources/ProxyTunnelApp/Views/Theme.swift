//
//  Theme.swift
//  ProxyTunnel
//
//  A small, explicit design system. Having the palette in one file keeps the
//  status colours consistent with the connection states, which matters more than
//  it sounds: the whole point of the connect screen is that the colour means
//  exactly one thing.
//

import SwiftUI
import ProxyTunnelCore

enum Theme {

    // MARK: Palette

    static let background = Color(red: 0.043, green: 0.055, blue: 0.082)
    static let surface = Color(red: 0.086, green: 0.102, blue: 0.145)
    static let surfaceElevated = Color(red: 0.118, green: 0.137, blue: 0.192)
    static let hairline = Color.white.opacity(0.08)

    static let accent = Color(red: 0.361, green: 0.549, blue: 1.0)
    static let success = Color(red: 0.235, green: 0.831, blue: 0.541)
    static let warning = Color(red: 1.0, green: 0.741, blue: 0.259)
    static let danger = Color(red: 1.0, green: 0.372, blue: 0.372)
    static let mock = Color(red: 0.796, green: 0.478, blue: 1.0)

    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)

    static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.055, green: 0.075, blue: 0.125),
            background
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: Status mapping

    static func color(for state: TunnelConnectionState) -> Color {
        switch state {
        case .disconnected:  return secondaryText
        case .connecting:    return warning
        case .connected:     return success
        case .disconnecting: return warning
        case .failed:        return danger
        }
    }

    static func symbol(for state: TunnelConnectionState) -> String {
        switch state {
        case .disconnected:  return "shield.slash"
        case .connecting:    return "arrow.triangle.2.circlepath"
        case .connected:     return "shield.lefthalf.filled"
        case .disconnecting: return "arrow.triangle.2.circlepath"
        case .failed:        return "exclamationmark.shield"
        }
    }

    static func color(forProtocol protocolType: ProxyProtocol) -> Color {
        switch protocolType {
        case .socks5:       return Color(red: 0.361, green: 0.749, blue: 0.996)
        case .httpConnect:  return Color(red: 0.988, green: 0.616, blue: 0.278)
        case .httpsConnect: return Color(red: 0.443, green: 0.859, blue: 0.639)
        }
    }
}

// MARK: - Reusable chrome

/// A rounded card used for every panel in the app.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

/// A key/value row used on the connection and diagnostics screens.
struct DetailRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    var valueColor: Color = Theme.primaryText
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 16)
            }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// A pinned notice. Used for the mock-mode banner, the entitlement warning and
/// the IPv6 leak warning — all of which must be impossible to miss and impossible
/// to mistake for decoration.
struct NoticeBanner: View {
    enum Level {
        case info, warning, danger, mock

        var color: Color {
            switch self {
            case .info:    return Theme.accent
            case .warning: return Theme.warning
            case .danger:  return Theme.danger
            case .mock:    return Theme.mock
            }
        }

        var symbol: String {
            switch self {
            case .info:    return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger:  return "xmark.octagon.fill"
            case .mock:    return "hammer.fill"
            }
        }
    }

    let level: Level
    let title: String
    let message: String?
    var action: (title: String, handler: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: level.symbol)
                    .foregroundStyle(level.color)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.title, action: action.handler)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(level.color)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(level.color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(level.color.opacity(0.35), lineWidth: 1)
        )
    }
}

/// A small pill showing a protocol name.
struct ProtocolBadge: View {
    let protocolType: ProxyProtocol

    var body: some View {
        Text(protocolType.displayName)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Theme.color(forProtocol: protocolType).opacity(0.18))
            )
            .foregroundStyle(Theme.color(forProtocol: protocolType))
    }
}

extension View {
    /// Standard full-screen background for the app.
    func appBackground() -> some View {
        background(Theme.backgroundGradient.ignoresSafeArea())
    }
}

// MARK: - Formatting

enum Format {
    static func duration(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "00:00" }
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func milliseconds(_ interval: TimeInterval?) -> String {
        guard let interval else { return "—" }
        return String(format: "%.0f ms", interval * 1000)
    }

    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(count))
    }
}
