import SwiftUI
import TunnelsCore

/// One machine: a bold row with its switch, then its forwards and any
/// started outside the app.
struct MachineSection: View {
    @Environment(AppModel.self) private var model
    let alias: String

    private var forwards: [Forward] { model.forwards(on: alias) }
    private var external: [ExternalForward] { model.external(on: alias) }

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

    private var isAuto: Bool { model.isAutoHost(alias) }

    private var header: some View {
        HStack(spacing: 6) {
            Text(alias).font(.system(size: 13, weight: .bold)).lineLimit(1)
            if isAuto {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("All ports")
                    .accessibilityLabel("all ports")
            }
            Spacer(minLength: 4)
            if !forwards.isEmpty || isAuto {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { forwards.contains { $0.desiredOn } || model.isWatching(alias) },
                        set: { model.setMachine(alias, on: $0) }
                    )
                )
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
        .contextMenu { hostMenu }
    }

    @ViewBuilder
    private var hostMenu: some View {
        // Toggles become checked menu items, so the tick is a real menu state
        // and the layout does not shift when the menu first appears.
        Toggle(
            "All Ports",
            isOn: Binding(
                get: { isAuto },
                set: { on in if on && !isAuto { model.enableAllPorts(alias) } }
            ))
        Toggle(
            "Pinned Ports Only",
            isOn: Binding(
                get: { !isAuto },
                set: { on in if on && isAuto { model.enablePinnedOnly(alias) } }
            ))
        Divider()
        Button("Copy ssh Command") { model.copySSHCommand(alias) }
            .disabled(!forwards.contains { $0.desiredOn })
        Button("Show Log") { model.showLog(alias) }
            .disabled(model.log(for: alias) == nil)
        Divider()
        Button("Forget Machine") { model.forgetMachine(alias) }
            .disabled(forwards.isEmpty && !isAuto)
    }

}

struct ExternalRow: View {
    @Environment(AppModel.self) private var model
    let forward: ExternalForward
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: "terminal")
            Text(forward.spec.isLoopbackRemote ? String(forward.spec.localPort) : forward.spec.remoteHost)
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
        // Stop is a hover control for the mouse; the menu and the action reach it from the keyboard and VoiceOver.
        .contextMenu { Button("Stop") { model.stopExternal(forward) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(forward.spec.portLabel) started outside Tunnels, process \(String(forward.pid))")
        .accessibilityAction(named: "Stop") { model.stopExternal(forward) }
    }
}
