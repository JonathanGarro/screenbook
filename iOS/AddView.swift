import SwiftUI
import WatchlistCore

// search tmdb and add

struct AddView: View {
    @Environment(PhoneModel.self) private var model
    @State private var text = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var pendingShow: SearchResult?

    var body: some View {
        List {
            if !model.hasKey {
                Text("Add your TMDB key in Settings, on the What's New tab, to search.").foregroundStyle(.secondary)
            } else if results.isEmpty && !text.isEmpty && !searching {
                Text("No results.").foregroundStyle(.secondary)
            }
            ForEach(results, id: \.id) { r in
                HStack(spacing: 12) {
                    Poster(url: r.posterURL, width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                        Text([r.kind == .tv ? "TV" : "Movie", r.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isTracked(r) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.title2)
                    } else {
                        Button {
                            if r.kind == .tv { pendingShow = r } else { Task { await model.add(r, caughtUp: false) } }
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.title2)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("Add")
        .searchable(text: $text, prompt: "Movies and TV shows")
        .task(id: text) {
            // a short pause so typing does not send a request per letter
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            searching = true
            results = await model.search(text)
            searching = false
        }
        .confirmationDialog(pendingShow?.displayTitle ?? "", isPresented: Binding(
            get: { pendingShow != nil }, set: { if !$0 { pendingShow = nil } }), titleVisibility: .visible) {
            if let r = pendingShow {
                Button("Start from the Beginning") { Task { await model.add(r, caughtUp: false) } }
                Button("I'm Caught Up") { Task { await model.add(r, caughtUp: true) } }
            }
        } message: {
            Text("Caught up marks every episode that has aired as watched.")
        }
    }
}

// settings

struct SettingsView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(model.hasKey ? "Saved" : "API key or read access token", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Key") {
                        let k = key
                        key = ""
                        Task { await model.saveKey(k) }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("TMDB")
                } footer: {
                    Text("Get a free key at themoviedb.org, under Settings, API. It stays on this iPhone.")
                }
                Section {
                    LabeledContent("Status", value: syncSummary)
                    Button("Sync Now") { Task { await model.cloud?.syncNow() } }
                } header: {
                    Text("iCloud Sync")
                } footer: {
                    Text("Your watchlist and watched episodes sync with Screenbook on your Mac. Reviews stay on the Mac.")
                }
                Section {
                    LabeledContent("Titles", value: "\(model.titles.count)")
                    if let last = model.lastChecked {
                        LabeledContent("Checked TMDB", value: last.formatted(.relative(presentation: .named)))
                    }
                    Button(model.checking ? "Checking..." : "Check TMDB Now") { Task { await model.check() } }
                        .disabled(model.checking || !model.hasKey)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var syncSummary: String {
        let st = model.syncStatus
        if let problem = st.problem { return problem }
        if st.pending > 0 { return "Sending \(st.pending)" }
        guard let last = st.lastSynced else { return "Waiting for iCloud" }
        return "Synced " + last.formatted(.relative(presentation: .named))
    }
}
