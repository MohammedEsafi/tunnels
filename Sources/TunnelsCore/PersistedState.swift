import Foundation

/// The forwards that were on when the app last quit, restored at launch.
public struct PersistedState: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var spec: ForwardSpec
        public var name: String
        public var isFavourite: Bool

        public init(spec: ForwardSpec, name: String, isFavourite: Bool) {
            self.spec = spec
            self.name = name
            self.isFavourite = isFavourite
        }
    }

    public var onForwards: [Entry]

    public init(onForwards: [Entry] = []) {
        self.onForwards = onForwards
    }

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Tunnels/state.json")
    }

    public static func load(from url: URL = defaultURL) -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return PersistedState()
        }
        return state
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    @MainActor
    public static func capture(from controller: ForwardController) -> PersistedState {
        PersistedState(onForwards: controller.forwards.filter(\.desiredOn).map {
            Entry(spec: $0.spec, name: $0.name, isFavourite: $0.isFavourite)
        })
    }
}
