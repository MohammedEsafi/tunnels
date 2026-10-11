import SwiftUI
import TunnelsCore

/// circle · name · (status on hover) · port column · switch
/// Clicking the name toggles the forward; clicking the port copies it.
struct ForwardRow: View {
    @Environment(AppModel.self) private var model
    let forward: Forward
    @State private var hovering = false

    /// Ad-hoc forwards are named by their port; show that once, as the name.
    private var portIsName: Bool { forward.name == String(forward.spec.remotePort) }

    var body: some View {
        HStack(spacing: 8) {
            if let retry {
                Button(action: retry) {
                    RowIcon(symbol: "arrow.clockwise", tint: tint)
                }
                .buttonStyle(.plain)
                .help(retryHelp)
                .accessibilityLabel(retryHelp)
            } else if forward.state == .pending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
                    .accessibilityLabel("Opening")
            } else {
                RowIcon(symbol: symbol, tint: tint)
            }
            Button {
                if forward.isDiscovered { model.excludePort(forward) } else { model.setForward(forward, on: !forward.desiredOn) }
            } label: {
                HStack(spacing: 6) {
                    Text(portIsName ? String(forward.spec.localPort) : forward.name)
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(forward.state == .off ? Color.primary.opacity(0.75) : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(forward.name) \(forward.spec.portLabel) on \(forward.spec.machine)")

            if hovering {
                Button {
                    if forward.isDiscovered { model.excludePort(forward) } else { model.removeForward(forward) }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(forward.isDiscovered ? "Not this port" : "Close and forget")
                .accessibilityLabel("Remove \(forward.name)")
            }
            if !portIsName || forward.spec.localPort != forward.spec.remotePort {
                PortColumn(spec: forward.spec)
            }
            Toggle("", isOn: Binding(
                get: { forward.desiredOn },
                set: { on in
                    if forward.isDiscovered { model.excludePort(forward) } else { model.setForward(forward, on: on) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("\(forward.name) switch")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RowHighlight(on: hovering))
        .onHover { hovering = $0 }
    }

    /// Dropped: retry the whole machine. Error: retry just this forward.
    private var retry: (() -> Void)? {
        switch forward.state {
        case .dropped: return { model.retryNow(forward.spec.machine) }
        case .error: return { model.setForward(forward, on: true) }
        default: return nil
        }
    }

    private var retryHelp: String {
        if case .error(let text) = forward.state { return "Retry · \(SSHErrorText.short(text))" }
        if case .failed(let reason) = model.controller.machineState(forward.spec.machine) { return "Retry · \(SSHErrorText.short(reason))" }
        return "Retry"
    }

    private var symbol: String {
        switch forward.state {
        case .error: return "exclamationmark"
        default: return "arrow.left.arrow.right"
        }
    }

    private var tint: Color? {
        switch forward.state {
        case .active: return .accentColor
        case .dropped: return .orange
        case .error: return .red
        case .pending, .off: return nil
        }
    }

}
