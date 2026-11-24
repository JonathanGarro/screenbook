import Foundation
import Observation
import WatchlistCore

// the chat pane: a conversation with claude about what to watch. replies stream in, and claude can
// search tmdb, check where something streams, read your reviews, and add titles (after you confirm).
// conversations are saved in the database on this mac, named by claude after the first exchange.

struct ChatItem: Identifiable, Codable {
    enum Kind: String, Codable { case user, assistant, activity, notice, recommendations }
    var id = UUID()
    let kind: Kind
    var text: String
    /// the picks, for a recommendations item
    var recs: RecSet?
}

/// up to four picks claude recommended, and the question that led to them (for Show more)
struct RecSet: Codable, Hashable {
    var question: String
    var picks: [Rec]
}

struct Rec: Codable, Hashable, Identifiable {
    var tmdbId: Int
    var mediaType: MediaType
    var title: String
    var year: String?
    var posterPath: String?
    var description: String
    var why: String

    var id: String { "\(mediaType.rawValue)-\(tmdbId)" }
    var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") } }
}

/// a title claude wants to add, waiting for a yes or no
struct PendingAdd: Identifiable {
    let id = UUID()
    let label: String
    let continuation: CheckedContinuation<Bool, Never>
}

@MainActor
@Observable
final class ChatModel {
    static let shared = ChatModel()

    var items: [ChatItem] = []
    var busy = false
    var pendingAdd: PendingAdd?
    /// true while claude is thinking and no reply text has arrived yet
    var waiting = false

    /// saved conversations, the most recent first
    var conversations: [ChatSummary] = []
    /// the open conversation, nil for a new one not yet sent
    var currentID: String?

    private var messages: [JSONObject] = []
    private var system: String?
    private var task: Task<Void, Never>?
    private var title = ""
    private var renamed = false
    private var createdAt = ""
    /// the message that started the exchange in progress, kept with any picks for Show more
    private var question = ""

    private var app: AppModel { AppModel.shared }

    var hasKey: Bool { apiKey != nil }

    private var apiKey: String? { APIKeyStore.resolve(app.paths, name: Claude.keyName) }

    // conversation

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, let key = apiKey else { return }
        if currentID == nil {
            currentID = UUID().uuidString
            title = Self.placeholderTitle(text)
            renamed = false
            createdAt = DateText.timestamp(Date())
        }
        let first = messages.isEmpty
        items.append(ChatItem(kind: .user, text: text))
        busy = true
        task = Task {
            await run(text, key: key)
            busy = false
            waiting = false
            save()
            if first, !messages.isEmpty, let id = currentID {
                await autoName(id, key: key)
            }
        }
    }

    func stop() {
        task?.cancel()
        answer(false)
    }

    func newChat() {
        stop()
        items = []
        messages = []
        system = nil
        currentID = nil
        title = ""
        renamed = false
    }

    // saved conversations

    func loadList() {
        conversations = (try? app.service?.db.chatSummaries()) ?? []
    }

    func open(_ id: String) {
        guard id != currentID, let saved = try? app.service?.db.chat(id) else { return }
        stop()
        currentID = saved.id
        title = saved.title
        renamed = saved.renamed
        createdAt = saved.createdAt
        system = saved.system
        messages = (try? JSONSerialization.jsonObject(with: Data(saved.messages.utf8))) as? [JSONObject] ?? []
        items = (try? JSONDecoder().decode([ChatItem].self, from: Data(saved.items.utf8))) ?? []
    }

    func rename(_ id: String, to newTitle: String) {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try? app.service?.db.renameChat(id, to: t, byUser: true)
        if id == currentID { title = t; renamed = true }
        loadList()
    }

    func delete(_ id: String) {
        try? app.service?.db.deleteChat(id)
        if id == currentID { newChat() }
        loadList()
    }

    func clearAll() {
        newChat()
        try? app.service?.db.deleteAllChats()
        loadList()
    }

    /// stores the open conversation once it has at least one finished exchange
    private func save() {
        guard let id = currentID, !messages.isEmpty, let db = app.service?.db else { return }
        let msgs = (try? JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let shown = (try? JSONEncoder().encode(items)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let chat = SavedChat(id: id, title: title, renamed: renamed, system: system ?? "", messages: msgs, items: shown,
                             createdAt: createdAt, updatedAt: DateText.timestamp(Date()))
        try? db.saveChat(chat)
        loadList()
    }

    static func placeholderTitle(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > 40 ? String(one.prefix(40)).trimmingCharacters(in: .whitespaces) + "..." : one
    }

    /// asks claude for a short name for the conversation, from its first exchange. keeps the placeholder on any failure.
    private func autoName(_ id: String, key: String) async {
        let user = items.first { $0.kind == .user }?.text ?? ""
        let reply = items.first { $0.kind == .assistant }?.text ?? ""
        var request = URLRequest(url: Claude.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Claude.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Claude.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        let body: JSONObject = [
            "model": Claude.model,
            "max_tokens": 2000,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "system": "You name chat conversations about movies and TV. Reply with only a title of 2 to 5 words, in title case, with no quotes and no ending punctuation.",
            "messages": [["role": "user", "content": "Name this conversation.\n\nUser: \(user.prefix(800))\n\nAssistant: \(reply.prefix(800))"]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        request.httpBody = data
        guard let (out, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: out)) as? JSONObject,
              json["stop_reason"] as? String != "refusal",
              let blocks = json["content"] as? [JSONObject] else { return }
        let name = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.\u{201C}\u{201D}")))
        guard !name.isEmpty, name.count <= 60 else { return }
        try? app.service?.db.renameChat(id, to: name, byUser: false)
        if id == currentID, !renamed { title = name }
        loadList()
    }

    func answer(_ yes: Bool) {
        guard let p = pendingAdd else { return }
        pendingAdd = nil
        p.continuation.resume(returning: yes)
    }

    /// asks for four new picks for the question behind a set of recommendations
    func showMore(_ recs: RecSet) {
        send("Show me four more recommendations for my earlier question: \u{201C}\(recs.question)\u{201D}. Pick different titles from the ones you have already suggested.")
    }

    /// adds a recommended title straight from its poster; the plus button is the confirmation
    func add(_ rec: Rec) async {
        guard let service = app.service, !isOnWatchlist(rec) else { return }
        do {
            _ = try await service.add(SearchResult(id: rec.tmdbId, mediaType: rec.mediaType.rawValue), caughtUp: false)
            app.reload()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func isOnWatchlist(_ rec: Rec) -> Bool {
        app.titles.contains { $0.tmdbId == rec.tmdbId && $0.mediaType == rec.mediaType }
    }

    private func run(_ text: String, key: String) async {
        if system == nil { system = await buildSystemPrompt() }
        // a show more request keeps the original question, so the next Show more asks the same thing
        question = text.hasPrefix("Show me four more recommendations for my earlier question: ")
            ? (items.last { $0.kind == .recommendations }?.recs?.question ?? text) : text
        let start = messages.count
        messages.append(["role": "user", "content": [["type": "text", "text": text]]])
        do {
            for _ in 0..<10 {
                let reply = try await stream(key: key)
                switch reply.stopReason {
                case "refusal":
                    rollback(to: start)
                    notice("Claude declined to answer that. Try asking another way.")
                    return
                case "max_tokens" where !reply.toolCalls.isEmpty:
                    rollback(to: start)
                    notice("Claude's reply was cut off. Try a narrower question.")
                    return
                default:
                    messages.append(["role": "assistant", "content": reply.historyContent])
                }
                guard reply.stopReason == "tool_use" else { return }
                var results: [JSONObject] = []
                for call in reply.toolCalls {
                    try Task.checkCancellation()
                    if let raw = reply.invalidToolInputs[call.id] {
                        results.append(errorResult(call.id, json(["INVALID_JSON": raw])))
                    } else {
                        results.append(await runTool(call.id, call.name, call.input))
                    }
                }
                messages.append(["role": "user", "content": results])
            }
            notice("Claude used a lot of steps without finishing. Try asking again.")
        } catch is CancellationError {
            rollback(to: start)
        } catch let error as URLError where error.code == .cancelled {
            rollback(to: start)
        } catch {
            rollback(to: start)
            notice(error.localizedDescription)
        }
    }

    /// drops an unfinished exchange so the next message starts from a clean history.
    /// only the tail goes, so every earlier turn (and its thinking) is sent back exactly as before.
    private func rollback(to count: Int) {
        if messages.count > count { messages.removeLast(messages.count - count) }
    }

    private func notice(_ text: String) {
        items.append(ChatItem(kind: .notice, text: text))
    }

    // request

    private func stream(key: String) async throws -> ReplyAccumulator {
        var request = URLRequest(url: Claude.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Claude.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("\(Claude.fallbackBeta),\(Claude.thinkingBindingBeta)", forHTTPHeaderField: "anthropic-beta")
        let body: JSONObject = [
            "model": Claude.model,
            "max_tokens": 32000,
            "thinking": ["type": "adaptive", "block_binding": ["prefix_mismatch_behavior": "drop_block"]],
            "stream": true,
            "system": [["type": "text", "text": system ?? ""]],
            "messages": messages,
            "tools": Self.tools,
            "output_config": ["effort": "medium"],
            // on a safety decline, the api retries on a model it picks for that category
            "fallbacks": "default",
            // caches everything up to the latest turn, so each follow-up rereads the profile cheaply
            "cache_control": ["type": "ephemeral"],
        ]
        // sorted keys keep every request byte-for-byte stable, which caching and replayed thinking rely on
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        waiting = true
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 20_000 { break } }
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? JSONObject)
                .flatMap { ($0["error"] as? JSONObject)?["message"] as? String } ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw AssistantError.http(status, message)
        }

        var reply = ReplyAccumulator()
        var bubble: Int?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = SSE.event(fromLine: line), let text = try reply.apply(event) else { continue }
            waiting = false
            if let i = bubble {
                items[i].text += text
            } else {
                items.append(ChatItem(kind: .assistant, text: text))
                bubble = items.count - 1
            }
        }
        waiting = false
        return reply
    }

    private func buildSystemPrompt() async -> String {
        let watchlist = app.libraryEntries.filter(\.onWatchlist).compactMap { e in
            app.title(e.id).map { ($0, e.status.rawValue) }
        }
        let mine = Set(app.config.myServices)
        let services = mine.isEmpty ? [] : await app.streamingServices().filter { mine.contains($0.providerId) }.map(\.providerName)
        return TasteProfile.systemPrompt(reviews: app.reviews, watchlist: watchlist, services: services,
                                         region: app.config.region, today: app.today)
    }

    // tools

    static let tools: [JSONObject] = {
        let id: JSONObject = ["type": "integer", "description": "The TMDB id, from search_tmdb or the user's lists"]
        let type: JSONObject = ["type": "string", "enum": ["movie", "tv"]]
        func tool(_ name: String, _ description: String, _ properties: JSONObject, _ required: [String]) -> JSONObject {
            ["name": name, "description": description, "eager_input_streaming": true,
             "input_schema": ["type": "object", "properties": properties, "required": required]]
        }
        return [
            tool("search_tmdb", "Search TMDB for movies and TV shows by title. Returns ids, years, short overviews, and whether each is already on the user's watchlist or rated.",
                 ["query": ["type": "string", "description": "A title or partial title"]], ["query"]),
            tool("title_details", "Details for one movie or show: overview, genres, status, seasons, and the user's own status and ratings for it.",
                 ["tmdb_id": id, "media_type": type], ["tmdb_id", "media_type"]),
            tool("where_to_watch", "Where a title streams, rents, or sells in the user's region, marking the services the user pays for.",
                 ["tmdb_id": id, "media_type": type], ["tmdb_id", "media_type"]),
            tool("read_review", "The user's own written review of a title they rated. For a show, pass season to pick one season's review.",
                 ["tmdb_id": id, "media_type": type, "season": ["type": "integer", "description": "Season number, for TV"]], ["tmdb_id", "media_type"]),
            tool("show_recommendations", "Show the user up to four recommended titles as cards with posters, an add button on each, and a Show more button. Use this for every recommendation of specific titles instead of listing them in text.",
                 ["picks": ["type": "array", "maxItems": 4, "description": "One to four picks, best first",
                            "items": ["type": "object",
                                      "properties": ["tmdb_id": id, "media_type": type,
                                                     "description": ["type": "string", "description": "One sentence about what it is"],
                                                     "why": ["type": "string", "description": "One sentence on why it fits them, tied to their ratings or request"]],
                                      "required": ["tmdb_id", "media_type", "description", "why"]]]],
                 ["picks"]),
            tool("add_to_watchlist", "Add a title to the user's watchlist. Only when the user asks. The app shows them a confirmation first and tells you whether they agreed.",
                 ["tmdb_id": id, "media_type": type], ["tmdb_id", "media_type"]),
        ]
    }()

    private func runTool(_ id: String, _ name: String, _ input: JSONObject) async -> JSONObject {
        guard let service = app.service, let client = service.client else {
            return errorResult(id, "TMDB is not set up in Screenbook.")
        }
        let tmdbId = input["tmdb_id"] as? Int
        let type = (input["media_type"] as? String).flatMap(MediaType.init(rawValue:))
        do {
            switch name {
            case "search_tmdb":
                guard let query = input["query"] as? String, !query.isEmpty else { return errorResult(id, "query is required") }
                activity("Searched TMDB for \u{201C}\(query)\u{201D}")
                let results = try await service.search(query).filter { $0.kind != nil }.prefix(8)
                return okResult(id, json(["results": results.map { r -> JSONObject in
                    var o: JSONObject = ["tmdb_id": r.id, "media_type": r.mediaType ?? "", "title": r.displayTitle]
                    if let y = r.year { o["year"] = y }
                    if let ov = r.overview, !ov.isEmpty { o["overview"] = String(ov.prefix(240)) }
                    if let kind = r.kind { o.merge(userFacts(r.id, kind)) { a, _ in a } }
                    return o
                }]))

            case "title_details":
                guard let tmdbId, let type else { return errorResult(id, "tmdb_id and media_type are required") }
                var o: JSONObject
                if type == .movie {
                    let m = try await client.movie(tmdbId)
                    activity("Looked up \(m.title)")
                    o = ["title": m.title, "media_type": "movie", "status": m.status ?? "", "overview": m.overview ?? "",
                         "genres": (m.genres ?? []).map(\.name)]
                    if let y = m.releaseDate?.prefix(4) { o["year"] = String(y) }
                    if let c = m.belongsToCollection { o["collection"] = c.name }
                } else {
                    let t = try await client.tv(tmdbId)
                    activity("Looked up \(t.name)")
                    o = ["title": t.name, "media_type": "tv", "status": t.status ?? "", "overview": t.overview ?? "",
                         "seasons": t.numberOfSeasons ?? 0, "type": t.type ?? ""]
                    if let y = t.firstAirDate?.prefix(4) { o["first_aired"] = String(y) }
                }
                o.merge(userFacts(tmdbId, type)) { a, _ in a }
                return okResult(id, json(o))

            case "where_to_watch":
                guard let tmdbId, let type else { return errorResult(id, "tmdb_id and media_type are required") }
                activity("Checked where to watch \(app.titleName(tmdbId, type) ?? "a title")")
                let region = app.config.region
                guard let info = try await client.providers(type, tmdbId, region: region, ttl: CacheTTL.streamingAlerts) else {
                    return okResult(id, "Not available to stream, rent, or buy in \(region) according to JustWatch.")
                }
                let mine = Set(app.config.myServices)
                func list(_ ps: [Provider]?) -> [String] {
                    (ps ?? []).map { $0.providerName + (mine.contains($0.providerId) ? " (one of their services)" : "") }
                }
                return okResult(id, json(["region": region, "subscription": list(info.flatrate), "free": list(info.free),
                                          "with_ads": list(info.ads), "rent": list(info.rent), "buy": list(info.buy)]))

            case "read_review":
                guard let tmdbId, let type else { return errorResult(id, "tmdb_id and media_type are required") }
                let season = input["season"] as? Int
                let found = app.reviews.filter { $0.tmdbId == tmdbId && $0.mediaType == type && (season == nil || $0.season == season) }
                guard !found.isEmpty else { return okResult(id, "They have not reviewed this title.") }
                activity("Read your review of \(found[0].noteTitle)")
                return okResult(id, json(["reviews": found.map { r -> JSONObject in
                    ["note": r.noteTitle, "rating": r.rating ?? 0, "finished_on": r.finishedOn ?? "", "season": r.season,
                     "text": String(r.body.prefix(6000))]
                }]))

            case "show_recommendations":
                guard let raw = input["picks"] as? [JSONObject], !raw.isEmpty else { return errorResult(id, "picks is required") }
                var picks: [Rec] = []
                var skipped: [String] = []
                for p in raw.prefix(4) {
                    guard let pid = p["tmdb_id"] as? Int, let ptype = (p["media_type"] as? String).flatMap(MediaType.init(rawValue:)) else {
                        skipped.append("a pick without a valid tmdb_id and media_type"); continue
                    }
                    let description = p["description"] as? String ?? ""
                    let why = p["why"] as? String ?? ""
                    // the title, year, and poster come from tmdb, so a wrong id shows up as the wrong title, not a made-up one
                    do {
                        if ptype == .movie {
                            let m = try await client.movie(pid)
                            picks.append(Rec(tmdbId: pid, mediaType: .movie, title: m.title, year: m.releaseDate.map { String($0.prefix(4)) },
                                             posterPath: m.posterPath, description: description, why: why))
                        } else {
                            let t = try await client.tv(pid)
                            picks.append(Rec(tmdbId: pid, mediaType: .tv, title: t.name, year: t.firstAirDate.map { String($0.prefix(4)) },
                                             posterPath: t.posterPath, description: description, why: why))
                        }
                    } catch {
                        skipped.append("\(ptype.rawValue) \(pid) (not found on TMDB)")
                    }
                }
                guard !picks.isEmpty else { return errorResult(id, "None of the picks could be found on TMDB: \(skipped.joined(separator: ", "))") }
                items.append(ChatItem(kind: .recommendations, text: "", recs: RecSet(question: question, picks: picks)))
                var note = "Shown to the user: " + picks.map { "\($0.title)\($0.year.map { " (\($0))" } ?? "")\(isOnWatchlist($0) ? " [already on their watchlist]" : "")" }.joined(separator: "; ")
                if !skipped.isEmpty { note += ". Skipped: " + skipped.joined(separator: ", ") }
                return okResult(id, note + ". Do not repeat them in text.")

            case "add_to_watchlist":
                guard let tmdbId, let type else { return errorResult(id, "tmdb_id and media_type are required") }
                if app.titles.contains(where: { $0.tmdbId == tmdbId && $0.mediaType == type }) {
                    return okResult(id, "Already on their watchlist.")
                }
                let label: String
                if type == .movie {
                    let m = try await client.movie(tmdbId)
                    label = m.title + (m.releaseDate.map { " (\($0.prefix(4)))" } ?? "")
                } else {
                    let t = try await client.tv(tmdbId)
                    label = t.name + (t.firstAirDate.map { " (\($0.prefix(4)))" } ?? "")
                }
                let yes = await withCheckedContinuation { c in pendingAdd = PendingAdd(label: label, continuation: c) }
                guard yes else {
                    activity("You declined adding \(label)")
                    return okResult(id, "The user declined. Do not add it.")
                }
                _ = try await service.add(SearchResult(id: tmdbId, mediaType: type.rawValue), caughtUp: false)
                app.reload()
                activity("Added \(label) to your watchlist")
                return okResult(id, "Added \(label) to their watchlist.")

            default:
                return errorResult(id, "Unknown tool \(name)")
            }
        } catch {
            return errorResult(id, error.localizedDescription)
        }
    }

    /// what the user already has to do with a title: watchlist status and ratings
    private func userFacts(_ tmdbId: Int, _ type: MediaType) -> JSONObject {
        var o: JSONObject = [:]
        if let e = app.libraryEntries.first(where: { $0.tmdbId == tmdbId && $0.mediaType == type }) {
            if e.onWatchlist { o["on_watchlist"] = e.status.rawValue }
        }
        let ratings = app.reviews.filter { $0.tmdbId == tmdbId && $0.mediaType == type }.compactMap(\.rating)
        if !ratings.isEmpty { o["their_ratings"] = ratings }
        return o
    }

    private func activity(_ text: String) {
        items.append(ChatItem(kind: .activity, text: text))
    }

    private func okResult(_ id: String, _ content: String) -> JSONObject {
        ["type": "tool_result", "tool_use_id": id, "content": content]
    }

    private func errorResult(_ id: String, _ content: String) -> JSONObject {
        ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": true]
    }

    private func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
