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
    @State private var loginNeedsApproval = false
    @State private var notificationsDenied = false

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
                    loginNeedsApproval = model.launchAtLoginNeedsApproval
                }
            if let loginError {
                Hint(loginError, warning: true)
            } else if loginNeedsApproval {
                Hint("Allow Tunnels under System Settings › General › Login Items.")
            }
            ToggleRow(title: "Notify about dropped connections", isOn: $model.notifyOnGiveUp)
                .onChange(of: model.notifyOnGiveUp) { _, _ in Task { notificationsDenied = await Notifier.isDenied() } }
            if model.notifyOnGiveUp && notificationsDenied {
                Hint("Notifications for Tunnels are off in System Settings.")
            }

            MenuSeparator()
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
        .onAppear {
            launchAtLogin = model.launchAtLogin
            loginNeedsApproval = model.launchAtLoginNeedsApproval
        }
        .task { notificationsDenied = await Notifier.isDenied() }
        .transition(pageTransition)
    }
}

/// One quiet line under a setting that needs the user's attention elsewhere.
private struct Hint: View {
    let text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(warning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

/// Machines by name; click one to see its ssh lines. Nothing else.
struct LogsPage: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var textHeight: CGFloat = 0
    @State private var tookSelection = false

    private var aliases: [String] { model.loggedAliases }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Connection Logs", back: .settings)
                .onAppear {
                    if !tookSelection, let wanted = model.logSelection { selected = wanted; model.logSelection = nil }
                    tookSelection = true
                }
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
                        Text((model.log(for: alias) ?? []).joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                GeometryReader { proxy in
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
