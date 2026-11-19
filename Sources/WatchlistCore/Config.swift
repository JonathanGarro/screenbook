import Foundation

// paths

/// locations of everything the app writes. one folder holds the database, the key file, and outputs/.
public struct AppPaths: Sendable {
    public let dataDir: URL

    public init(dataDir: URL) {
        self.dataDir = dataDir
    }

    public var databaseURL: URL { dataDir.appendingPathComponent("watchlist.db") }
    public var outputsDir: URL { dataDir.appendingPathComponent("outputs") }
    public var digestURL: URL { outputsDir.appendingPathComponent("digest.md") }
    public var csvURL: URL { outputsDir.appendingPathComponent("watchlist.csv") }
    public var configURL: URL { dataDir.appendingPathComponent("config.json") }
    public var envURL: URL { dataDir.appendingPathComponent(".env") }

    /// default is ~/Library/Application Support/Watchlist, overridable with WATCHLIST_DATA_DIR.
    public static func standard(override: String? = nil) -> AppPaths {
        if let override, !override.isEmpty {
            return AppPaths(dataDir: URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        if let env = ProcessInfo.processInfo.environment["WATCHLIST_DATA_DIR"], !env.isEmpty {
            return AppPaths(dataDir: URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppPaths(dataDir: support.appendingPathComponent("Watchlist"))
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outputsDir, withIntermediateDirectories: true)
    }
}

// config

public struct AppConfig: Codable, Equatable, Sendable {
    /// iso 3166-1 country code used for release dates and streaming providers
    public var region: String = "US"
    /// streaming lookups are off unless turned on
    public var streamingEnabled: Bool = false
    /// show rent and buy providers in addition to flatrate
    public var includeRentBuy: Bool = false
    /// the app runs a check each time it opens
    public var checkOnLaunch: Bool = true
    /// show the unwatched count in the menu bar
    public var showInMenuBar: Bool = true
    /// post a macos notification when a check finds new episodes
    public var notifyNewEpisodes: Bool = true
    /// post a macos notification when a saved movie's release date arrives
    public var notifyMovieReleases: Bool = true
    /// while the app is running, check again once the last check is this old
    public var periodicCheck: Bool = true

    public init(region: String = "US", streamingEnabled: Bool = false, includeRentBuy: Bool = false,
                checkOnLaunch: Bool = true, showInMenuBar: Bool = true,
                notifyNewEpisodes: Bool = true, notifyMovieReleases: Bool = true, periodicCheck: Bool = true) {
        self.region = region
        self.streamingEnabled = streamingEnabled
        self.includeRentBuy = includeRentBuy
        self.checkOnLaunch = checkOnLaunch
        self.showInMenuBar = showInMenuBar
        self.notifyNewEpisodes = notifyNewEpisodes
        self.notifyMovieReleases = notifyMovieReleases
        self.periodicCheck = periodicCheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        region = (try? c.decode(String.self, forKey: .region)) ?? "US"
        streamingEnabled = (try? c.decode(Bool.self, forKey: .streamingEnabled)) ?? false
        includeRentBuy = (try? c.decode(Bool.self, forKey: .includeRentBuy)) ?? false
        checkOnLaunch = (try? c.decode(Bool.self, forKey: .checkOnLaunch)) ?? true
        showInMenuBar = (try? c.decode(Bool.self, forKey: .showInMenuBar)) ?? true
        notifyNewEpisodes = (try? c.decode(Bool.self, forKey: .notifyNewEpisodes)) ?? true
        notifyMovieReleases = (try? c.decode(Bool.self, forKey: .notifyMovieReleases)) ?? true
        periodicCheck = (try? c.decode(Bool.self, forKey: .periodicCheck)) ?? true
    }
}

public enum ConfigStore {
    public static func load(_ paths: AppPaths) -> AppConfig {
        guard let data = try? Data(contentsOf: paths.configURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    public static func save(_ config: AppConfig, _ paths: AppPaths) throws {
        try paths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: paths.configURL, options: .atomic)
    }
}

// api key

/// the key is never stored in source. lookup order: TMDB_API_KEY env var, then .env in the data folder.
public enum APIKeyStore {
    public static let variableName = "TMDB_API_KEY"

    public static func resolve(_ paths: AppPaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let value = environment[variableName]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if let text = try? String(contentsOf: paths.envURL, encoding: .utf8),
           let value = parseEnv(text)[variableName], !value.isEmpty {
            return value
        }
        return nil
    }

    /// writes the key to the data folder .env with owner-only permissions
    public static func save(_ key: String, _ paths: AppPaths) throws {
        try paths.ensureDirectories()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if let text = try? String(contentsOf: paths.envURL, encoding: .utf8) {
            lines = text.components(separatedBy: .newlines).filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("\(variableName)=") && !$0.isEmpty
            }
        }
        if !trimmed.isEmpty {
            lines.append("\(variableName)=\(trimmed)")
        }
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: paths.envURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.envURL.path)
    }

    public static func parseEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }
}
