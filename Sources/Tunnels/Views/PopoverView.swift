import SwiftUI
import TunnelsCore

/// The menu: bold machine rows with a switch, quiet forward rows with a
/// circled icon, a right-aligned port column and a switch. The host:port
/// field lives behind the + button.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @State private var listHeight: CGFloat = 0

    private var showsQuickOpen: Bool {
        model.quickOpenVisible || (model.sectionAliases.isEmpty && model.favouritesProblems.isEmpty)
    }

    var body: some View {
        Group {
            switch model.menuPage {
            case .main: mainPage
            case .settings: SettingsPage()
            case .logs: LogsPage()
            }
        }
        .padding(6)
        .font(.system(size: 13))
        // Menus do not draw keyboard focus rings; the field takes focus itself.
        .focusEffectDisabled()
        .animation(.easeInOut(duration: 0.18), value: pageIndex)
    }

    private var pageIndex: Int {
        switch model.menuPage {
        case .main: return 0
        case .settings: return 1
        case .logs: return 2
        }
    }

    private var mainPage: some View {
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
            MenuRow("Close All", enabled: model.anyDesired) { model.closeAll() }
            MenuSeparator()
            MenuRow("Settings…") { model.menuPage = .settings }
                .keyboardShortcut(",")
            MenuRow("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
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
