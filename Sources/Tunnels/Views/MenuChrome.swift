import SwiftUI
import TunnelsCore

struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }
}

/// A plain text row, like "Wi-Fi Settings…" at the bottom of the Wi-Fi menu.
struct MenuRow: View {
    let title: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(enabled ? .primary : .tertiary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .background(RowHighlight(on: hovering && enabled))
        .onHover { hovering = $0 }
    }
}

/// The translucent rounded highlight Control Center uses on hover.
struct RowHighlight: View {
    let on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(on ? 0.10 : 0))
    }
}

/// The circled symbol at the start of Control Center rows.
struct RowIcon: View {
    let symbol: String
    var tint: Color?

    var body: some View {
        ZStack {
            Circle().fill(tint ?? Color.primary.opacity(0.12))
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint == nil ? Color.primary.opacity(0.7) : .white)
        }
        .frame(width: 22, height: 22)
    }
}

/// Right-aligned local port, with "→ remote" only when the two differ.
/// Clicking copies localhost:<port>.
struct PortColumn: View {
    @Environment(AppModel.self) private var model
    let spec: ForwardSpec
    @State private var copied = false

    var body: some View {
        Button {
            model.copyAddress(of: spec)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                copied = false
            }
        } label: {
            Group {
                if copied {
                    Text("Copied").foregroundStyle(.secondary)
                } else if spec.localPort == spec.remotePort {
                    Text(String(spec.localPort)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 3) {
                        Text(String(spec.localPort)).foregroundStyle(.primary)
                        Text("→").foregroundStyle(.tertiary)
                        Text(String(spec.remotePort)).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .lineLimit(1)
            .frame(minWidth: 92, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy localhost:\(spec.localPort)")
        .accessibilityLabel("Copy localhost \(spec.localPort)")
    }
}
