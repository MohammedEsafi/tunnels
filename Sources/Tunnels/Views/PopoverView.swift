import SwiftUI
import TunnelsCore

/// Variant D: bold machine rows with a switch, quiet forward rows with a
/// circled icon, a right-aligned port column and a switch. Detail shows on
/// hover. The host:port field lives behind the + button.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @State private var listHeight: CGFloat = 0

    private var showsQuickOpen: Bool {
        model.quickOpenVisible || (model.sectionAliases.isEmpty && model.favouritesProblems.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsQuickOpen {
                QuickOpenField()
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            }

            // A ScrollView has no intrinsic height, so measure the content and
            // size the scroll area to it, up to a cap.
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.favouritesProblems.isEmpty {
                        problemsRow
                    }
                    ForEach(model.sectionAliases, id: \.self) { alias in
                        MachineSection(alias: alias)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { listHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, next in listHeight = next }
                })
            }
            .frame(height: min(listHeight, 620))

            MenuSeparator()
            MenuRow("Close All", enabled: model.controller.anyDesired) { model.closeAll() }
            MenuSeparator()
            MenuRow("Settings…") { SettingsWindow.shared.show(model: model) }
                .keyboardShortcut(",")
            MenuRow("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(6)
        .font(.system(size: 13))
        // Menus do not draw keyboard focus rings; the field takes focus itself.
        .focusEffectDisabled()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Tunnels").font(.system(size: 13, weight: .bold))
            Spacer()
            if !model.sectionAliases.isEmpty {
            Button {
                model.quickOpenVisible.toggle()
            } label: {
                Image(systemName: model.quickOpenVisible ? "xmark" : "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(model.quickOpenVisible ? .white : .primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(model.quickOpenVisible ? Color.accentColor : Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(model.quickOpenVisible ? "Hide" : "Open a forward")
            .accessibilityLabel(model.quickOpenVisible ? "Hide the open field" : "Open a forward")
            .keyboardShortcut("n")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private var problemsRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RowIcon(symbol: "exclamationmark", tint: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Favourites file has problems").font(.system(size: 13))
                ForEach(model.favouritesProblems, id: \.self) { problem in
                    Text(problem).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Open") { model.openFavouritesFile() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

}

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
    var emphasis = false
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
                    Text(String(spec.localPort)).foregroundStyle(emphasis ? .primary : .secondary)
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
