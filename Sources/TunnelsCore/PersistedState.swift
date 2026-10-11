import Foundation

/// The forwards that were on when the app last quit, restored at launch.
public struct PersistedState: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var spec: ForwardSpec
        public var name: String

        public init(spec: ForwardSpec, name: String) {
            self.spec = spec
            self.name = name
        }
    }

    public var onForwards: [Entry]
    /// Machines that were in all-ports mode and switched on.
    public var autoHostsOn: [String]

    public init(onForwards: [Entry] = [], autoHostsOn: [String] = []) {
        self.onForwards = onForwards
        self.autoHostsOn = autoHostsOn
    }

    enum CodingKeys: String, CodingKey { case onForwards, autoHostsOn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onForwards = try c.decodeIfPresent([Entry].self, forKey: .onForwards) ?? []
        autoHostsOn = try c.decodeIfPresent([String].self, forKey: .autoHostsOn) ?? []
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
        PersistedState(
            onForwards: controller.forwards.filter { $0.desiredOn && !$0.isDiscovered }.map {
                Entry(spec: $0.spec, name: $0.name)
            },
            autoHostsOn: controller.autoHosts.sorted()
        )
    }
}
