import SwiftUI
import WatchlistCore

// chat with claude about what to watch (detail column), with a short explainer beside it (middle column)

struct ChatView: View {
    @State private var chat = ChatModel.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

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
                Divider()
                composer
            }
            .onAppear { focused = true }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.items.isEmpty { starters }
                    ForEach(chat.items) { item in row(item) }
                    if chat.waiting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking...").foregroundStyle(.secondary)
                        }
                    }
                    if let p = chat.pendingAdd { confirm(p) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
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
                Spacer(minLength: 60)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.16)))
            }
        case .assistant:
            Text(markdown(item.text))
                .textSelection(.enabled)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity:
            Label(item.text, systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notice:
            Label(item.text, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.orange)
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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about what to watch", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
            if chat.busy {
                Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .help("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Theme.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send")
            }
        }
        .padding(12)
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

struct ChatSidebar: View {
    @State private var chat = ChatModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                chat.newChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .disabled(chat.items.isEmpty)

            Text("How it works").font(.headline)
            Text("Each chat starts by giving Claude your ratings, your watchlist, and the streaming services you picked in Settings. It can search TMDB, check where a title streams, read one of your reviews when it helps, and add titles after you confirm.")
                .foregroundStyle(.secondary)
            Text("Privacy and cost").font(.headline)
            Text("Chat is off until you add your own Anthropic API key. What Claude sees is sent to Anthropic under that key, and Anthropic bills it, usually a few cents per chat. Chats are not saved.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
