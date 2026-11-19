// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Watchlist",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WatchlistApp", targets: ["WatchlistApp"]),
        .executable(name: "watchlist", targets: ["watchlist"]),
    ],
    targets: [
        .target(
            name: "WatchlistCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "WatchlistApp", dependencies: ["WatchlistCore"]),
        .executableTarget(name: "watchlist", dependencies: ["WatchlistCore"]),
        .testTarget(name: "WatchlistCoreTests", dependencies: ["WatchlistCore"]),
    ],
    swiftLanguageModes: [.v5]
)
