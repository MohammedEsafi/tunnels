import SwiftUI
import TunnelsCore

/// circle · name · port column · switch
/// Clicking the name toggles the forward; clicking the port copies it.
/// Everything else is in the right-click menu. Rename and Change Local Port
/// edit in place in the row.
struct ForwardRow: View {
    @Environment(AppModel.self) private var model
    let forward: Forward
    @State private var hovering = false
    @State private var editing: Editing?
    @State private var draft = ""
    @FocusState private var focused: Bool

    enum Editing { case name, port }

    var body: some View {
        HStack(spacing: 8) {
            leadingIcon

            if editing == .name {
                inlineField(placeholder: forward.name)
            } else {
                Button {
                    if forward.isDiscovered { model.excludePort(forward) } else { model.setForward(forward, on: !forward.desiredOn) }
                } label: {
                    HStack(spacing: 6) {
                        Text(forward.name)
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
            }

            if editing == .port {
                HStack(spacing: 3) {
                    inlineField(placeholder: String(forward.spec.localPort)).frame(width: 64)
                    Text("→ \(String(forward.spec.remotePort))").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if !portIsName || forward.spec.localPort != forward.spec.remotePort {
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    /// Ad-hoc forwards are named by their port; show that once, as the name.
    private var portIsName: Bool { forward.name == String(forward.spec.remotePort) }

    @ViewBuilder
    private var leadingIcon: some View {
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
        } else if forward.state == .noService {
            RowIcon(symbol: symbol, tint: .orange)
                .help("Nothing listening on \(forward.spec.machine):\(String(forward.spec.remotePort))")
                .accessibilityLabel("Nothing listening on \(forward.spec.machine) port \(String(forward.spec.remotePort))")
        } else {
            RowIcon(symbol: symbol, tint: tint)
        }
    }

    // MARK: Menu

    @ViewBuilder
    private var menu: some View {
        Button("Copy localhost:\(String(forward.spec.localPort))") { model.copyAddress(of: forward.spec) }
        Button("Open in Browser") { model.openInBrowser(forward.spec) }
        Divider()
        // On a discovered port, renaming or moving it pins it as a side effect.
        Button("Rename…") { begin(.name, with: forward.name) }
        Button("Change Local Port…") { begin(.port, with: String(forward.spec.localPort)) }
        Divider()
        if forward.isDiscovered {
            Button("Not This Port") { model.excludePort(forward) }
        } else {
            Button("Close and Forget") { model.removeForward(forward) }
        }
    }

    // MARK: Inline editing

    private func begin(_ what: Editing, with text: String) {
        draft = text
        editing = what
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    private func inlineField(placeholder: String) -> some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .monospacedDigit()
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand { editing = nil }
            .onChange(of: focused) { _, isFocused in if !isFocused && editing != nil { commit() } }
            .padding(.horizontal, 5)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor))
    }

    private func commit() {
        guard let what = editing else { return }
        editing = nil
        let text = draft.trimmingCharacters(in: .whitespaces)
        switch what {
        case .name:
            if !text.isEmpty { model.renameForward(forward, to: text) }
        case .port:
            if let port = Int(text) { model.changeLocalPort(forward, to: port) }
        }
    }

    // MARK: State

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
        case .noService, .dropped: return .orange
        case .error: return .red
        case .pending, .off: return nil
        }
    }
}
