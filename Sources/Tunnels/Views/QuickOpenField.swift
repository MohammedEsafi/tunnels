import SwiftUI
import TunnelsCore

/// host:port entry with suggestions from favourites and SSH config hosts,
/// drawn as a vibrant rounded field like the search fields in system menus.
struct QuickOpenField: View {
    @Environment(AppModel.self) private var model
    /// -1 = nothing highlighted; the empty-field list is a menu, not a selection.
    @State private var highlighted = -1
    @FocusState private var focused: Bool

    private var text: String {
        get { model.quickOpenText }
        nonmutating set { model.quickOpenText = newValue }
    }

    private var suggestions: [Suggestion] {
        QuickOpen.suggestions(for: text, favourites: model.favourites, hosts: model.hosts)
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("host:port or favourite", text: $model.quickOpenText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onChange(of: model.quickOpenText) { _, next in
                        highlighted = next.trimmingCharacters(in: .whitespaces).isEmpty ? -1 : 0
                        if next.hasSuffix(":") { focused = true }
                    }
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
            .onAppear { requestFocus() }
            .onChange(of: model.popoverVisible) { _, visible in if visible { requestFocus() } }

            if !suggestions.isEmpty {
                VStack(spacing: 1) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        SuggestionRow(suggestion: suggestion, highlighted: index == highlighted)
                            .onHover { if $0 { highlighted = index } }
                            .onTapGesture { choose(suggestion) }
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
        }
    }

    /// The panel becomes key a moment after the view appears.
    private func requestFocus() {
        focused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
    }

    private func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        if highlighted < 0 {
            highlighted = delta > 0 ? 0 : suggestions.count - 1
        } else {
            highlighted = (highlighted + delta + suggestions.count) % suggestions.count
        }
    }

    private func submit() {
        let list = suggestions
        if !list.isEmpty, highlighted >= 0, highlighted < list.count {
            choose(list[highlighted])
        } else if let spec = QuickOpen.parse(text) {
            model.open(spec)
            text = ""
        }
    }

    private func choose(_ suggestion: Suggestion) {
        switch suggestion {
        case .favourite(let favourite):
            model.open(favourite)
            text = ""
        case .spec(let spec):
            model.open(spec)
            text = ""
        case .host(let host):
            text = host.name + ":"
            focused = true
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 6) {
            switch suggestion {
            case .favourite(let favourite):
                Text(favourite.name)
                Text(favourite.spec.portLabel).foregroundStyle(secondary).font(.system(size: 12)).monospacedDigit()
                Text(favourite.spec.machine).foregroundStyle(secondary).font(.system(size: 11))
                Spacer()
                Text("Favourite").foregroundStyle(secondary).font(.system(size: 11))
            case .host(let host):
                Text(host.name)
                if host.online == false {
                    Text("offline").foregroundStyle(secondary).font(.system(size: 11))
                }
                Spacer()
                Text(host.source == .tailscale ? "Tailscale" : "SSH config").foregroundStyle(secondary).font(.system(size: 11))
            case .spec(let spec):
                Text("Open \(spec.portLabel) on \(spec.machine)")
                if spec.remoteHost != "localhost" {
                    Text("via \(spec.remoteHost)").foregroundStyle(secondary).font(.system(size: 11))
                }
                Spacer()
                Text("↩").foregroundStyle(secondary).font(.system(size: 11))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(highlighted ? .white : .primary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(highlighted ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    private var secondary: Color {
        highlighted ? .white.opacity(0.8) : .secondary
    }
}
