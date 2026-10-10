// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tunnels",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tunnels", targets: ["Tunnels"]),
        .library(name: "TunnelsCore", targets: ["TunnelsCore"]),
        .executable(name: "tunnelsctl", targets: ["tunnelsctl"]),
    ],
    targets: [
        .target(
            name: "TunnelsCore",
            path: "Sources/TunnelsCore"
        ),
        .executableTarget(
            name: "Tunnels",
            dependencies: ["TunnelsCore"],
            path: "Sources/Tunnels"
        ),
        .executableTarget(
            name: "tunnelsctl",
            dependencies: ["TunnelsCore"],
            path: "Sources/tunnelsctl"
        ),
        .testTarget(
            name: "TunnelsCoreTests",
            dependencies: ["TunnelsCore"],
            path: "Tests/TunnelsCoreTests"
        ),
    ]
)
