import SwiftUI
import TunnelsCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            LogsSettings()
                .tabItem { Label("Logs", systemImage: "doc.text") }
        }
        .frame(width: 520, height: 380)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Start Tunnels at login", isOn: $launchAtLogin)
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
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Favourites") {
                LabeledContent("File") {
                    Text(model.favouritesURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Open in Editor") { model.openFavouritesFile() }
                    Button("Reveal in Finder") { model.revealFavouritesFile() }
                    Spacer()
                    Text("\(model.favourites.count) favourite\(model.favourites.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                if !model.favouritesProblems.isEmpty {
                    ForEach(model.favouritesProblems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Section("SSH") {
                LabeledContent("Hosts in ~/.ssh/config") {
                    Text("\(model.hosts.count)")
                }
                LabeledContent("Keys in agent") {
                    Text("Managed by ssh-agent. Use ssh-add in Terminal.").foregroundStyle(.secondary)
                }
                Button("Reload Hosts") { model.reloadHosts() }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.launchAtLogin }
    }
}

private struct LogsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String = ""

    private var aliases: [String] { model.controller.logs.keys.sorted() }
    private var lines: [String] { model.controller.logs[selected] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Machine", selection: $selected) {
                    ForEach(aliases, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button("Clear") { model.controller.clearLog(alias: selected) }
                    .disabled(selected.isEmpty)
            }
            ScrollView {
                Text(lines.isEmpty ? "No output yet." : lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        }
        .padding(16)
        .onAppear { if selected.isEmpty { selected = aliases.first ?? "" } }
        .onChange(of: aliases) { _, next in if !next.contains(selected) { selected = next.first ?? "" } }
    }
}
