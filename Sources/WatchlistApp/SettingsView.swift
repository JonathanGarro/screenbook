import SwiftUI
import UserNotifications
import WatchlistCore

// settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var saved = false
    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined
    @State private var omdbKey = ""
    @State private var omdbSaved = false

    static let regions: [(String, String)] = [
        ("US", "United States"), ("CA", "Canada"), ("GB", "United Kingdom"), ("IE", "Ireland"),
        ("AU", "Australia"), ("NZ", "New Zealand"), ("DE", "Germany"), ("FR", "France"),
        ("ES", "Spain"), ("IT", "Italy"), ("NL", "Netherlands"), ("SE", "Sweden"),
        ("NO", "Norway"), ("DK", "Denmark"), ("FI", "Finland"), ("BR", "Brazil"),
        ("MX", "Mexico"), ("IN", "India"), ("JP", "Japan"), ("KR", "South Korea"),
    ]

    var body: some View {
        Form {
            Section("TMDB") {
                SecureField("API key or read access token", text: $key)
                HStack {
                    Text(model.hasKey ? "A key is set." : "No key set.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                    Button("Save Key") {
                        model.saveKey(key)
                        key = ""
                        saved = true
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Stored in the data folder .env file. The TMDB_API_KEY environment variable takes priority if set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Checking") {
                Toggle("Check for new releases when the app opens", isOn: binding(\.checkOnLaunch))
                Toggle("Show unwatched count in the menu bar", isOn: binding(\.showInMenuBar))
                Text("Details are cached for an hour, so reopening the app often does not refetch everything. While the menu bar count is on, closing the window keeps Watchlist running; use Cmd+Q to quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify me when new episodes air", isOn: binding(\.notifyNewEpisodes))
                Toggle("Notify me when a saved movie is released", isOn: binding(\.notifyMovieReleases))
                Toggle("Check every 6 hours while Watchlist is running", isOn: binding(\.periodicCheck))
                HStack {
                    Text(statusText).foregroundStyle(.secondary)
                    Spacer()
                    if notifyStatus == .denied {
                        Button("Open System Settings") { Notifier.openSystemSettings() }
                    }
                    Button("Send Test") {
                        Task {
                            await Notifier.sendTest()
                            notifyStatus = await Notifier.status()
                        }
                    }
                    .disabled(!Notifier.available)
                }
                Text("Each episode and release is announced once. Clicking a notification opens the title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Region") {
                Picker("Country", selection: binding(\.region)) {
                    ForEach(Self.regionOptions(current: model.config.region), id: \.0) { code, name in
                        Text("\(name) (\(code))").tag(code)
                    }
                }
                Text("Used for movie release dates and streaming availability.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Streaming") {
                Toggle("Show where to watch", isOn: binding(\.streamingEnabled))
                Toggle("Include rent and buy options", isOn: binding(\.includeRentBuy))
                    .disabled(!model.config.streamingEnabled)
                Text(Attribution.justWatch + " Cached for 30 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Obsidian Reviews") {
                LabeledContent("Vault") {
                    HStack {
                        Text(vaultLabel).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose...") { chooseVault() }
                        if !model.config.obsidianVaultPath.isEmpty {
                            Button("Auto") { set(\.obsidianVaultPath, "") }.help("Use the vault Obsidian has open")
                        }
                    }
                }
                TextField("Movie folder", text: binding(\.obsidianFilmFolder), prompt: Text("Film"))
                TextField("TV season folder", text: binding(\.obsidianTVFolder), prompt: Text("Television"))
                TextField("Show index folder", text: binding(\.obsidianIndexFolder), prompt: Text("Leave empty to skip"))
                Text("Folders are relative to the vault. When a season links to a show with no index note, one is created in the index folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("OMDb API key (optional)", text: $omdbKey)
                HStack {
                    Text(model.hasOMDbKey ? "OMDb key set. IMDb, Metascore, and Rotten Tomatoes fill in for movies." : "Without it those fields stay blank. Free key at omdbapi.com.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if omdbSaved { Text("Saved").foregroundStyle(.secondary) }
                    Button("Save Key") {
                        model.saveOMDbKey(omdbKey)
                        omdbKey = ""
                        omdbSaved = true
                    }
                    .disabled(omdbKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Data") {
                LabeledContent("Folder") {
                    Text(model.paths.dataDir.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Show in Finder") { model.revealDataFolder() }
                Text(Attribution.tmdb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 820)
        .task {
            notifyStatus = await Notifier.status()
        }
    }

    private var vaultLabel: String {
        if let v = ObsidianVault.resolve(model.config) {
            return model.config.obsidianVaultPath.isEmpty ? "\(v.lastPathComponent) (auto)" : v.path
        }
        return "None found"
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Vault"
        if let current = ObsidianVault.resolve(model.config) { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url {
            set(\.obsidianVaultPath, url.path)
        }
    }

    private func set(_ path: WritableKeyPath<AppConfig, String>, _ value: String) {
        var c = model.config
        c[keyPath: path] = value
        model.saveConfig(c)
    }

    private var statusText: String {
        guard Notifier.available else { return "Unavailable when run with swift run." }
        switch notifyStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed in System Settings."
        case .denied: return "Turned off in System Settings."
        default: return "Not asked yet."
        }
    }

    private func binding<T>(_ path: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { model.config[keyPath: path] },
            set: { value in
                var c = model.config
                c[keyPath: path] = value
                model.saveConfig(c)
            }
        )
    }

    /// keeps a region set from the cli selectable even if it is not in the short list
    static func regionOptions(current: String) -> [(String, String)] {
        regions.contains { $0.0 == current } ? regions : [(current, current)] + regions
    }
}
