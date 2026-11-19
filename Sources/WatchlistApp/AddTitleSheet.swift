import SwiftUI
import WatchlistCore

// add sheet

struct AddTitleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var selected: Int?
    @State private var caughtUp = false
    @State private var searching = false
    @State private var adding = false
    @State private var message: String?

    private var choice: SearchResult? { results.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Movie or Show").font(.title2.bold())
            HStack {
                TextField("Search TMDB", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }

            Group {
                if searching {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message {
                    Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results, selection: $selected) { r in
                        ResultRow(result: r, saved: model.isSaved(r)).tag(r.id)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }
            }
            .frame(minHeight: 300)

            if choice?.kind == .tv {
                Toggle("I'm caught up (mark every aired episode watched)", isOn: $caughtUp)
            }

            HStack {
                Text("Search results from TMDB").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(adding ? "Adding..." : "Add") {
                    Task { await add() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil || adding || choice.map(model.isSaved) == true)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        message = nil
        defer { searching = false }
        do {
            results = Array(try await model.search(text).prefix(20))
            selected = results.first?.id
            if results.isEmpty { message = "No movies or shows found." }
        } catch {
            results = []
            message = error.localizedDescription
        }
    }

    private func add() async {
        guard let choice else { return }
        adding = true
        defer { adding = false }
        if await model.add(choice, caughtUp: caughtUp) {
            dismiss()
        }
    }
}

struct ResultRow: View {
    let result: SearchResult
    let saved: Bool

    var body: some View {
        HStack(spacing: 10) {
            Poster(url: result.posterURL, width: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.displayTitle).font(.headline).lineLimit(1)
                    Text(result.year.map(String.init) ?? "").foregroundStyle(.secondary)
                }
                Text(result.overview ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(result.kind?.label ?? "")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                if saved {
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
