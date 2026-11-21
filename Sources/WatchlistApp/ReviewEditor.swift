import SwiftUI
import WatchlistCore

// editor

struct ReviewEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var review: Review
    @State private var sending = false
    @State private var sentURL: URL?
    @State private var conflict: ReviewError?
    @State private var error: String?
    @State private var confirmDelete = false

    private var finishedBinding: Binding<Date> {
        Binding(
            get: { Self.date(review.finishedOn) ?? Date() },
            set: { review.finishedOn = DateText.day($0) }
        )
    }

    private var seriesIndexText: Binding<String> {
        Binding(
            get: { review.seriesIndex.map(String.init) ?? "" },
            set: { review.seriesIndex = Int($0.trimmingCharacters(in: .whitespaces)) }
        )
    }

    private var connectedText: Binding<String> {
        Binding(get: { review.connectedTo ?? "" }, set: { review.connectedTo = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(review.mediaType == .movie ? "Movie Review" : "Season \(review.season) Review").font(.title2.bold())
                Spacer()
                statusBadge
            }

            Form {
                TextField("Note title", text: $review.noteTitle)
                LabeledContent("Rating") {
                    HStack(spacing: 12) {
                        StarPicker(rating: $review.rating)
                        Text(review.rating.map(ObsidianNote.number) ?? "Not rated")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if review.rating != nil {
                            Button("Clear") { review.rating = nil }
                                .buttonStyle(.link)
                        }
                    }
                }
                DatePicker("Finished on", selection: finishedBinding, displayedComponents: .date)
                Toggle("Rewatch", isOn: $review.rewatch)
                TextField("Connected to", text: connectedText, prompt: Text(review.mediaType == .movie ? "Series, e.g. James Bond" : "Show index note"))
                if review.mediaType == .movie {
                    TextField("Series index", text: seriesIndexText, prompt: Text("Optional number"))
                }
            }
            .formStyle(.columns)

            Text("Review").font(.headline)
            TextEditor(text: $review.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .frame(minHeight: 260)

            Text("Saves to \(ObsidianNote.relativePath(review, config: model.config))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if review.isSent {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(sentURL == nil ? "In Obsidian" : "Sent to Obsidian")
                    Button("Open in Obsidian") { open() }
                        .buttonStyle(.link)
                    Button("Locate Note...") { locate() }
                        .buttonStyle(.link)
                        .help("Link this review to a note in the vault, for notes sent before Watchlist tracked IDs")
                }
                .font(.callout)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                if model.hasSavedReview(review) {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Draft") {
                    model.saveReview(review)
                    dismiss()
                }
                Button(sending ? "Sending..." : (review.isSent ? "Update in Obsidian" : "Send to Obsidian")) {
                    Task { await send(overwrite: false) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sending || review.noteTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 720)
        .confirmationDialog(conflictTitle, isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })) {
            Button("Replace Note", role: .destructive) { Task { await send(overwrite: true) } }
            Button("Cancel", role: .cancel) { conflict = nil }
        } message: {
            Text(conflict?.localizedDescription ?? "")
        }
        .confirmationDialog("Delete this review?", isPresented: $confirmDelete) {
            Button("Delete Review", role: .destructive) {
                model.deleteReview(review)
                dismiss()
            }
        } message: {
            Text(review.isSent ? "This removes it from Watchlist only. The note in Obsidian stays." : "The draft will be lost.")
        }
    }

    private var conflictTitle: String {
        if case .noteExists(_, let edited) = conflict, edited { return "Note changed in Obsidian" }
        return "Note already exists"
    }

    @ViewBuilder
    private var statusBadge: some View {
        let text = review.isSent ? "In Obsidian" : (model.hasSavedReview(review) ? "Draft" : "New")
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(review.isSent ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15)))
    }

    private func open() {
        error = nil
        do {
            review = try model.openInObsidian(review)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.allowsMultipleSelection = false
        panel.prompt = "Link Note"
        panel.message = "Choose the Obsidian note for this review"
        if let vault = ObsidianVault.resolve(model.config) {
            let folder = review.mediaType == .movie ? model.config.obsidianFilmFolder : model.config.obsidianTVFolder
            panel.directoryURL = vault.appendingPathComponent(folder)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        do {
            review = try model.relinkNote(review, file: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send(overwrite: Bool) async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            let result = try await model.sendReview(review, overwrite: overwrite)
            review = result.review
            sentURL = result.url
        } catch let e as ReviewError {
            if case .noteExists = e { conflict = e } else { error = e.localizedDescription }
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func date(_ day: String?) -> Date? {
        guard let day else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }
}

// stars

/// five stars with half-star precision. click or drag: the left half of a star gives a half star.
struct StarPicker: View {
    @Binding var rating: Double?
    var size: CGFloat = 24
    var spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: spacing) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: symbol(i))
                        .font(.system(size: size))
                        .frame(width: size, height: size)
                        .foregroundStyle(Color.yellow)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { rating = value(at: $0.location.x) })
            .help("Click the left half of a star for a half star, or drag")

            Stepper("Rating", value: Binding(
                get: { rating ?? 0 },
                set: { rating = $0 <= 0 ? nil : min(5, $0) }
            ), in: 0...5, step: 0.5)
            .labelsHidden()
            .help("Adjust by half a star")
        }
    }

    /// maps a horizontal position to a rating in half-star steps
    private func value(at x: CGFloat) -> Double {
        let unit = size + spacing
        let index = max(0, min(4, Int(floor(x / unit))))
        let within = x - CGFloat(index) * unit
        let half: Double = within < size / 2 ? 0.5 : 1
        return Double(index) + half
    }

    private func symbol(_ i: Int) -> String {
        let r = rating ?? 0
        if r >= Double(i) { return "star.fill" }
        if r >= Double(i) - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// read-only stars for lists
struct StarsLabel: View {
    let rating: Double?

    var body: some View {
        if let rating {
            Text(ObsidianNote.stars(rating).isEmpty ? "0" : ObsidianNote.stars(rating))
                .foregroundStyle(.yellow)
        } else {
            Text("Unrated").foregroundStyle(.secondary)
        }
    }
}

// reviews list

struct ReviewsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let drafts = model.reviews.filter { !$0.isSent }
        let sent = model.reviews.filter(\.isSent).sorted { ($0.finishedOn ?? "") > ($1.finishedOn ?? "") }
        if model.reviews.isEmpty {
            ContentUnavailableView {
                Label("No Reviews Yet", systemImage: "star.bubble")
            } description: {
                Text("Open a movie and click Write Review, or open a show and review a season.")
            }
        } else {
            List {
                if !drafts.isEmpty {
                    Section("Drafts") {
                        ForEach(drafts) { r in row(r) }
                    }
                }
                if !sent.isEmpty {
                    Section("Sent to Obsidian") {
                        ForEach(sent) { r in row(r) }
                    }
                }
            }
        }
    }

    private func row(_ r: Review) -> some View {
        Button {
            model.editingReview = r
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.noteTitle).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        StarsLabel(rating: r.rating)
                        Text(DateText.pretty(r.finishedOn)).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                Spacer()
                Image(systemName: r.mediaType == .movie ? "film" : "tv").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
