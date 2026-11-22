import SwiftUI
import WatchlistCore

// fill imdb and rotten tomatoes

struct FillRatingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var refresh = false
    @State private var running = false
    @State private var progress = ""
    @State private var summary: RatingsFillSummary?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fill IMDb and Rotten Tomatoes").font(.title2.bold())
            Text("For each movie review linked to a note, Watchlist looks the film up on OMDb by its IMDb id and fills imdb_id, imdb_link, imdb_rating, imdb_votes, metascore, rotten_tomatoes, and my_rating_delta where they are blank or missing. Nothing else in the note changes.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Also refresh values that are already filled (scores change over time)", isOn: $refresh)
                .disabled(running)

            if running {
                HStack { ProgressView().controlSize(.small); Text(progress).foregroundStyle(.secondary).monospacedDigit() }
            }
            if let s = summary {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Updated \(s.updated.count) notes", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(s.alreadyComplete) already complete, \(s.checked) checked.").foregroundStyle(.secondary)
                    if !s.notOnOMDb.isEmpty { Text("Not on OMDb: \(s.notOnOMDb.sorted().joined(separator: ", "))").font(.caption) }
                    if !s.noImdbId.isEmpty { Text("No IMDb id: \(s.noImdbId.sorted().joined(separator: ", "))").font(.caption) }
                    if !s.noteMissing.isEmpty { Text("Note not found: \(s.noteMissing.sorted().joined(separator: ", "))").font(.caption) }
                    if !s.errors.isEmpty { Text(s.errors.joined(separator: "\n")).font(.caption).foregroundStyle(.red) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if !model.hasOMDbKey {
                Text("Needs an OMDb key. Add it in Settings, Obsidian Reviews.").foregroundStyle(.orange)
            }

            Spacer()
            HStack {
                Spacer()
                Button(summary == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if summary == nil {
                    Button("Fill Ratings") { Task { await run() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || !model.hasOMDbKey)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }

    private func run() async {
        guard let service = model.service else { return }
        running = true
        error = nil
        defer { running = false }
        do {
            summary = try await service.fillRatings(refresh: refresh) { done, total in
                Task { @MainActor in progress = "Checking \(done) of \(total)" }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
