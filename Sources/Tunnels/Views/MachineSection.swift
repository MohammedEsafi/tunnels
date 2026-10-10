import SwiftUI
import TunnelsCore

/// One machine: a bold row with its switch, then its forwards. State shows as
/// a small dot; the reason and countdown appear on hover.
struct MachineSection: View {
    @Environment(AppModel.self) private var model
    let alias: String

    private var forwards: [Forward] { model.controller.forwards(on: alias) }
    private var external: [ExternalForward] { model.external(on: alias) }
    private var state: MachineState { model.controller.machineState(alias) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(forwards) { forward in
                ForwardRow(forward: forward)
            }
            ForEach(external) { forward in
                ExternalRow(forward: forward)
            }
        }
        .padding(.bottom, 2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(alias).font(.system(size: 13, weight: .bold)).lineLimit(1)
            if inTrouble {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                    .help(reason)
                    .accessibilityLabel(reason)
            }
            Spacer(minLength: 4)
            if !forwards.isEmpty {
                Toggle("", isOn: Binding(
                    get: { forwards.contains { $0.desiredOn } },
                    set: { model.setMachine(alias, on: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("All forwards on \(alias)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .padding(.top, 4)
    }

    private var inTrouble: Bool {
        switch state {
        case .dropped, .failed: return true
        default: return false
        }
    }

    /// Tooltip on the orange dot; the only place the words live.
    private var reason: String {
        switch state {
        case .dropped: return "Connection dropped, retrying"
        case .failed(let text): return SSHErrorText.short(text)
        default: return ""
        }
    }
}

struct ExternalRow: View {
    @Environment(AppModel.self) private var model
    let forward: ExternalForward
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: "terminal")
            Text(forward.spec.remoteHost == "localhost" || forward.spec.remoteHost == "127.0.0.1"
                 ? String(forward.spec.localPort)
                 : "\(forward.spec.remoteHost)")
                .font(.system(size: 13))
                .monospacedDigit()
            if hovering {
                Text("Started outside Tunnels · pid \(String(forward.pid))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button("Stop") { model.stopExternal(forward) }
                    .controlSize(.small)
            } else if forward.spec.localPort != forward.spec.remotePort {
                PortColumn(spec: forward.spec)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RowHighlight(on: hovering))
        .onHover { hovering = $0 }
    }
}
