// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Screenbook",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WatchlistApp", targets: ["WatchlistApp"]),
        .executable(name: "screenbook", targets: ["screenbook"]),
    ],
    dependencies: [
        // installs updates from the appcast on github, checked against the release's signing key
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "WatchlistCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "WatchlistApp",
            dependencies: ["WatchlistCore", .product(name: "Sparkle", package: "Sparkle")],
            // build_app.sh puts Sparkle.framework in Contents/Frameworks, and swift run finds it beside the binary
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
        .executableTarget(name: "screenbook", dependencies: ["WatchlistCore"]),
        .testTarget(name: "WatchlistCoreTests", dependencies: ["WatchlistCore"]),
    ],
    swiftLanguageModes: [.v5]
)
