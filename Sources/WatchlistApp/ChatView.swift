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
