import SwiftUI
import WatchlistCore

// chat with claude about what to watch (detail column), with a short explainer beside it (middle column)

struct ChatView: View {
    @State private var chat = ChatModel.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// the width of the conversation, shared by the bubbles and the text box
    static let column: CGFloat = 680

    static let suggestions = [
        "What should I watch tonight?",
        "Recommend a movie I'd love, based on my 5-star films",
        "Something on my services under two hours",
        "Which show on my watchlist should I start next?",
    ]

    var body: some View {
        if !chat.hasKey {
            ContentUnavailableView {
                Label("Add a Claude API Key", systemImage: "key")
            } description: {
                Text("Chat uses your own Anthropic API key. Create one at console.anthropic.com, then paste it in Settings, under Claude.")
            } actions: {
                SettingsLink { Text("Open Settings") }
            }
        } else {
            VStack(spacing: 0) {
                transcript
                composer
                    .frame(maxWidth: Self.column)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
            }
            .onAppear { focused = true }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if chat.items.isEmpty { starters }
                    ForEach(chat.items) { item in row(item) }
                    if chat.waiting {
                        TypingBubble()
                    }
                    if let p = chat.pendingAdd { confirm(p) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: Self.column + 40, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.items.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.pendingAdd?.id) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask Claude what to watch").font(.title2.bold())
            Text("Claude knows your ratings, your watchlist, and your streaming services, and can look things up on TMDB.")
                .foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.self) { s in
                Button { chat.send(s) } label: {
                    Text(s)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.12)))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Bubble(fromMe: true).fill(Theme.accent))
            }
            .padding(.top, 6)
        case .assistant:
            HStack {
                Text(markdown(item.text))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Bubble(fromMe: false).fill(Color.secondary.opacity(0.14)))
                Spacer(minLength: 80)
            }
        case .activity:
            Label(item.text, systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        case .notice:
            Label(item.text, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
        case .recommendations:
            if let recs = item.recs { RecommendationCard(recs: recs) }
        }
    }

    private func confirm(_ p: PendingAdd) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent).font(.title3)
            Text("Add **\(p.label)** to your watchlist?")
            Spacer()
            Button("Not Now") { chat.answer(false) }
            Button("Add") { chat.answer(true) }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about what to watch", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 4)
            if chat.busy {
                Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Theme.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send")
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(focused ? Theme.accent.opacity(0.6) : Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private func send() {
        guard !chat.busy else { return }
        chat.send(draft)
        draft = ""
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// claude's picks: four covers in a row with an add button on each, a bullet per pick, then Show more
struct RecommendationCard: View {
    let recs: RecSet
    @State private var chat = ChatModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(recs.picks) { PosterTile(rec: $0) }
                // keeps covers the same size when there are fewer than four
                ForEach(0..<max(0, 4 - recs.picks.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(recs.picks) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}").foregroundStyle(.secondary)
                        Text(bullet(p)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button {
                chat.showMore(recs)
            } label: {
                Label("Show more", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .disabled(chat.busy)
            .help("Ask Claude for four different picks")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.10)))
    }

    private func bullet(_ p: Rec) -> AttributedString {
        var name = AttributedString(p.title)
        name.font = .body.bold()
        var meta = AttributedString(" (\([p.year, p.mediaType == .tv ? "TV" : "Movie"].compactMap { $0 }.joined(separator: ", ")))  ")
        meta.foregroundColor = .secondary
        var why = AttributedString(p.why.isEmpty ? "" : "  Why: ")
        why.font = .body.italic()
        return name + meta + AttributedString(p.description) + why + AttributedString(p.why)
    }
}

/// one cover with a plus button at the top right, or a check once it is on the watchlist
struct PosterTile: View {
    let rec: Rec
    @State private var chat = ChatModel.shared
    @State private var adding = false

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                AsyncImage(url: rec.posterURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Text(rec.title).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) { badge.padding(6) }
            .frame(maxWidth: .infinity)
            .help("\(rec.title)\(rec.year.map { " (\($0))" } ?? "")")
    }

    @ViewBuilder
    private var badge: some View {
        if chat.isOnWatchlist(rec) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.green)
                .shadow(radius: 2)
                .help("On your watchlist")
        } else if adding {
            ProgressView().controlSize(.small).padding(4).background(Circle().fill(.white))
        } else {
            Button {
                adding = true
                Task {
                    await chat.add(rec)
                    adding = false
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.accent)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .help("Add \(rec.title) to your watchlist")
        }
    }
}

struct ChatSidebar: View {
    @State private var chat = ChatModel.shared
    @State private var renaming: ChatSummary?
    @State private var newName = ""
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    chat.newChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(chat.currentID == nil && chat.items.isEmpty)
                Spacer()
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("How Ask Claude works")
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { info }
            }
            .padding(10)

            if chat.conversations.isEmpty {
                ContentUnavailableView("No Chats Yet", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Conversations are saved here, named by Claude. Right-click one to rename it."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { chat.currentID }, set: { if let id = $0 { chat.open(id) } })) {
                    ForEach(chat.conversations) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.body.weight(.medium)).lineLimit(2)
                            Text(Self.when(c.updatedAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(c.id)
                        .contextMenu {
                            Button("Rename...") {
                                newName = c.title
                                renaming = c
                            }
                            Divider()
                            Button("Delete", role: .destructive) { chat.delete(c.id) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { chat.loadList() }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let c = renaming { chat.rename(c.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How it works").font(.headline)
            Text("Each chat starts by giving Claude your ratings, your watchlist, and the streaming services you picked in Settings. It can search TMDB, check where a title streams, read one of your reviews when it helps, and add titles after you confirm.")
            Text("Privacy and cost").font(.headline)
            Text("What Claude sees is sent to Anthropic under your API key, and Anthropic bills it, usually a few cents per chat. Chats are saved only on this Mac; clear them in Settings, under Claude.")
        }
        .font(.callout)
        .frame(width: 300)
        .padding(16)
    }

    static func when(_ timestamp: String) -> String {
        guard let d = DateText.parseTimestamp(timestamp) else { return "" }
        return d.formatted(.relative(presentation: .named))
    }
}

/// a rounded message bubble with a small tail at the bottom corner, on the right for your messages
struct Bubble: Shape {
    let fromMe: Bool

    func path(in rect: CGRect) -> Path {
        // drawn for the right side as one outline, then mirrored for claude's bubbles on the left
        let w = rect.width, h = rect.height, r = min(16, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: h), radius: r)
        p.addLine(to: CGPoint(x: w, y: h - 9))
        // the tail curls out past the corner and tucks back under the bubble
        p.addQuadCurve(to: CGPoint(x: w + 6, y: h), control: CGPoint(x: w, y: h - 2))
        p.addQuadCurve(to: CGPoint(x: w - 11, y: h - 2.5), control: CGPoint(x: w - 4, y: h + 0.5))
        p.addQuadCurve(to: CGPoint(x: w - 18, y: h), control: CGPoint(x: w - 14, y: h))
        p.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: 0), radius: r)
        p.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: w, y: 0), radius: r)
        p.closeSubpath()
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        if !fromMe { t = t.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1) }
        return p.applying(t)
    }
}

/// three dots in a bubble while claude is thinking
struct TypingBubble: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 7, height: 7).opacity(phase == i ? 0.9 : 0.35)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Bubble(fromMe: false).fill(Color.secondary.opacity(0.14)))
            Spacer()
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
        .accessibilityLabel("Claude is thinking")
    }
}
