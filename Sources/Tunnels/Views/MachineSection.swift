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

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.modeQuestion == alias {
                question
            }
            ForEach(forwards) { forward in
                ForwardRow(forward: forward)
            }
            ForEach(external) { forward in
                ExternalRow(forward: forward)
            }
        }
        .padding(.bottom, 2)
    }

    private var isAuto: Bool { model.isAutoHost(alias) }

    private var header: some View {
        HStack(spacing: 6) {
            Text(alias).font(.system(size: 13, weight: .bold)).lineLimit(1)
            if isAuto {
                Image(systemName: "infinity")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("All ports")
                    .accessibilityLabel("all ports")
            }
            Spacer(minLength: 4)
            if hovering && isAuto {
                Button {
                    model.forgetAutoHost(alias)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop watching all ports and forget")
                .accessibilityLabel("Forget all ports on \(alias)")
            }
            if !forwards.isEmpty || isAuto {
                Toggle("", isOn: Binding(
                    get: { forwards.contains { $0.desiredOn } || model.isWatching(alias) || model.modeQuestion == alias },
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Asked when an all-ports host is switched on.
    private var question: some View {
        HStack(spacing: 8) {
            Button("All ports") { model.enableAllPorts(alias) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            Button("Pinned only") { model.enablePinnedOnly(alias) }
                .controlSize(.small)
                .disabled(forwards.isEmpty)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
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
