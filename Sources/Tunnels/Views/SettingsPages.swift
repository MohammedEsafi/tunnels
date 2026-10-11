import SwiftUI
import TunnelsCore

/// "‹ Title" header for a sub-page, like Control Center's Sound or Focus pages.
struct PageHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    var back: AppModel.MenuPage = .main
    @State private var hovering = false

    var body: some View {
        Button {
            model.menuPage = back
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 13, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RowHighlight(on: hovering))
        .onHover { hovering = $0 }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .accessibilityLabel("Back")
    }
}

/// A row that navigates to a sub-page, with an optional detail and chevron.
struct LinkRow: View {
    let title: String
    var detail: String?
    var external = false
    var chevronDown = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Image(systemName: external ? "arrow.up.forward" : (chevronDown ? "chevron.down" : "chevron.right"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RowHighlight(on: hovering))
        .onHover { hovering = $0 }
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        let pageTransition = AnyTransition.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing))
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings")

            ToggleRow(title: "Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != model.launchAtLogin else { return }
                    do {
                        try model.setLaunchAtLogin(enabled)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = model.launchAtLogin
                    }
                }
            if let loginError {
                Text(loginError).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 10)
            }
            ToggleRow(title: "Notify about dropped connections", isOn: $model.notifyOnGiveUp)

            MenuSeparator()
            LinkRow(title: "Forwards", detail: (model.favourites.count + model.autoHosts.count) == 0 ? nil : "\(model.favourites.count + model.autoHosts.count)") { model.menuPage = .pinned }
            LinkRow(title: "Favourites File", external: true) { model.openFavouritesFile() }
            LinkRow(title: "SSH Config", external: true) { model.openSSHConfig() }
            LinkRow(title: "Connection Logs") { model.menuPage = .logs }

            MenuSeparator()
            HStack {
                Text("Tunnels \(model.appVersion)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
        }
        .onAppear { launchAtLogin = model.launchAtLogin }
        .transition(pageTransition)
    }
}

/// Every remembered forward, with inline rename. × forgets.
struct PinnedPage: View {
    @Environment(AppModel.self) private var model
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Forwards", back: .settings)
            ForEach(model.autoHosts, id: \.self) { host in
                AutoHostRow(host: host)
            }
            if model.favourites.isEmpty && model.autoHosts.isEmpty {
                Text("Nothing yet. Forwards you open are remembered here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(model.favourites, id: \.self) { favourite in
                        PinnedRow(favourite: favourite)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { listHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, next in listHeight = next }
                })
            }
            .frame(height: min(listHeight, 420))
            if !model.favourites.isEmpty {
                MenuSeparator()
                Text("Click a name to rename it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: 22)
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
    }
}

private struct AutoHostRow: View {
    @Environment(AppModel.self) private var model
    let host: AutoHost
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).font(.system(size: 13))
                Text([
                    host.excluded.isEmpty ? "all ports" : "all ports except \(host.excluded.sorted().map(String.init).joined(separator: ", "))",
                    host.offset.map { "moved ports +\($0)" },
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hovering {
                Button {
                    model.forgetAutoHost(host.name)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Forget")
                .accessibilityLabel("Forget \(host.name)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RowHighlight(on: hovering))
        .onHover { hovering = $0 }
    }
}

private struct PinnedRow: View {
    @Environment(AppModel.self) private var model
    let favourite: Favourite
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var detail: String {
        let ports = favourite.spec.localPort == favourite.spec.remotePort
            ? String(favourite.spec.localPort)
            : "\(favourite.spec.localPort) → \(favourite.spec.remotePort)"
        let host = favourite.spec.remoteHost == "localhost" ? "" : " via \(favourite.spec.remoteHost)"
        return "\(favourite.spec.machine) · \(ports)\(host)"
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if editing {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit { commit() }
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, isFocused in if !isFocused && editing { commit() } }
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.25)))
                        .padding(.horizontal, -4)
                } else {
                    Button {
                        draft = favourite.name
                        editing = true
                        focused = true
                    } label: {
                        Text(favourite.name).font(.system(size: 13)).lineLimit(1).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rename")
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer()
            if hovering && !editing {
                Button {
                    model.forget(favourite)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Forget")
                .accessibilityLabel("Forget \(favourite.name)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RowHighlight(on: hovering))
        .onHover { hovering = $0 }
    }

    private func commit() {
        editing = false
        model.rename(favourite, to: draft)
    }
}

/// Machines by name; click one to see its ssh lines. Nothing else.
struct LogsPage: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String? = ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT_LOG"]
    @State private var textHeight: CGFloat = 0

    private var aliases: [String] { model.controller.logs.keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Connection Logs", back: .settings)
            if aliases.isEmpty {
                Text("No connections yet.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            ForEach(aliases, id: \.self) { alias in
                LinkRow(title: alias, chevronDown: selected == alias) {
                    selected = selected == alias ? nil : alias
                }
                if selected == alias {
                    // A ScrollView has no intrinsic height in this panel: size it to
                    // the text, up to a cap, like the other lists.
                    ScrollView {
                        Text((model.controller.logs[alias] ?? []).joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(GeometryReader { proxy in
                                Color.clear
                                    .onAppear { textHeight = proxy.size.height }
                                    .onChange(of: proxy.size.height) { _, next in textHeight = next }
                            })
                    }
                    .frame(height: min(max(textHeight, 24), 240))
                }
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
    }
}
