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
    @State private var claudeKey = ""
    @State private var claudeSaved = false

    static let regions: [(String, String)] = [
        ("US", "United States"), ("CA", "Canada"), ("GB", "United Kingdom"), ("IE", "Ireland"),
        ("AU", "Australia"), ("NZ", "New Zealand"), ("DE", "Germany"), ("FR", "France"),
        ("ES", "Spain"), ("IT", "Italy"), ("NL", "Netherlands"), ("SE", "Sweden"),
        ("NO", "Norway"), ("DK", "Denmark"), ("FI", "Finland"), ("BR", "Brazil"),
        ("MX", "Mexico"), ("IN", "India"), ("JP", "Japan"), ("KR", "South Korea"),
    ]

    private var syncSummary: String {
        let st = model.syncStatus
        if let problem = st.problem { return problem }
        if st.pending > 0 { return "Sending \(st.pending) changes" }
        guard let last = st.lastSynced else { return "Waiting for iCloud" }
        return "Up to date, synced " + last.formatted(.relative(presentation: .named))
    }

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
                Text("Details are cached for an hour, so reopening the app often does not refetch everything. While the menu bar count is on, closing the window keeps Screenbook running; use Cmd+Q to quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify me when new episodes air", isOn: binding(\.notifyNewEpisodes))
                Toggle("Notify me when a saved movie is released", isOn: binding(\.notifyMovieReleases))
                Toggle("Check every 6 hours while Screenbook is running", isOn: binding(\.periodicCheck))
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

            Section("My Streaming Services") {
                StreamingServicesPicker()
                Toggle("Notify me when a saved title comes to my services", isOn: binding(\.notifyStreaming))
                    .disabled(model.config.myServices.isEmpty)
                Text("Each check looks up your saved movies and shows on these services, at most once a day per title, and What's New lists the ones that arrived. Titles already on a service when you pick it are not announced. Watched movies and stopped titles are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude") {
                SecureField("Anthropic API key", text: $claudeKey)
                HStack {
                    Text(model.hasClaudeKey ? "A key is set. Ask Claude is on." : "No key set. Ask Claude stays off.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if claudeSaved { Text("Saved").foregroundStyle(.secondary) }
                    Button("Save Key") {
                        model.saveClaudeKey(claudeKey)
                        claudeKey = ""
                        claudeSaved = true
                    }
                    .disabled(claudeKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Ask Claude sends your ratings, watchlist, streaming services, and the reviews it reads to Anthropic under your key, which Anthropic bills (usually a few cents per chat). Create a key at console.anthropic.com. Stored in the data folder .env file; the ANTHROPIC_API_KEY environment variable takes priority.")
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

            Section("Updates") {
                if model.updates.available {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { model.updates.automaticChecks }, set: { model.updates.setAutomaticChecks($0) }))
                    Toggle("Download and install updates automatically", isOn: Binding(
                        get: { model.updates.automaticInstalls }, set: { model.updates.setAutomaticInstalls($0) }))
                        .disabled(!model.updates.automaticChecks)
                    HStack {
                        Text("Version \(model.updates.current ?? "")").foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { model.updates.check() }
                    }
                } else {
                    Text("Updates are available in release builds.").foregroundStyle(.secondary)
                }
            }

            Section("iCloud Sync") {
                if model.cloud != nil {
                    HStack {
                        Text(syncSummary).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync Now") { model.syncNow() }
                    }
                    Text("Your watchlist and watched episodes sync with Screenbook on your other devices. Reviews stay on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("iCloud sync is available in builds signed with the iCloud capability.").foregroundStyle(.secondary)
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

// streaming services you subscribe to

struct StreamingServicesPicker: View {
    @Environment(AppModel.self) private var model
    @State private var options: [Provider] = []
    @State private var loading = false
    @State private var filter = ""

    var body: some View {
        let mine = Set(model.config.myServices)
        let shown = options.filter { filter.isEmpty || $0.providerName.localizedCaseInsensitiveContains(filter) }
            .sorted { (mine.contains($0.providerId) ? 0 : 1) < (mine.contains($1.providerId) ? 0 : 1) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary(mine)).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            if loading && options.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if options.isEmpty {
                Text(model.hasKey ? "No services found for your region." : "Add a TMDB key to choose services.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown, id: \.providerId) { p in
                            Toggle(isOn: Binding(get: { mine.contains(p.providerId) }, set: { toggle(p.providerId, $0) })) {
                                HStack(spacing: 8) {
                                    AsyncImage(url: p.logoURL) { $0.resizable() } placeholder: { Color.secondary.opacity(0.15) }
                                        .frame(width: 22, height: 22)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    Text(p.providerName)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 220)
            }
        }
        .task(id: model.config.region) {
            loading = true
            options = await model.streamingServices()
            loading = false
        }
    }

    private func summary(_ mine: Set<Int>) -> String {
        let names = options.filter { mine.contains($0.providerId) }.map(\.providerName)
        if names.isEmpty { return mine.isEmpty ? "None chosen" : "\(mine.count) chosen" }
        return ListFormatter.localizedString(byJoining: names)
    }

    private func toggle(_ id: Int, _ on: Bool) {
        var c = model.config
        var ids = Set(c.myServices)
        if on { ids.insert(id) } else { ids.remove(id) }
        c.myServices = ids.sorted()
        model.saveConfig(c)
    }
}
