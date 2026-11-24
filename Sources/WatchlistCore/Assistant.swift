import Foundation

// the chat pane's connection to claude: request settings, rebuilding a streamed reply, and the
// taste profile built from your ratings. there is no official swift sdk, so this speaks the
// messages api over http, the same way the tmdb client does.

public enum Claude {
    public static let model = "claude-opus-5-5"
    public static let apiVersion = "2026-10-21"
    /// lets the api retry on another model if a safety classifier declines a request
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let keyName = "ANTHROPIC_API_KEY"
}

public enum AssistantError: LocalizedError, Equatable {
    case http(Int, String)
    case stream(String)

    public var errorDescription: String? {
        switch self {
        case .http(401, _): return "Claude rejected the API key. Check it in Settings."
        case .http(429, _): return "Claude is rate limiting this key. Try again in a minute."
        case .http(let code, let message): return "Claude request failed (\(code)): \(message)"
        case .stream(let message): return "Claude stopped partway: \(message)"
        }
    }
}

/// a json object, as the api sends and expects it
public typealias JSONObject = [String: Any]

// streamed replies

/// rebuilds the content blocks of a streamed reply from its server-sent events, so the turn can be sent
/// back unchanged (thinking blocks and their signatures included) on the next request
public struct ReplyAccumulator {
    public private(set) var blocks: [JSONObject] = []
    public private(set) var stopReason: String?
    public private(set) var refusalCategory: String?
    public private(set) var model: String?
    /// tool calls whose input was not valid json, by tool_use id, with the raw text received
    public private(set) var invalidToolInputs: [String: String] = [:]
    private var partialJSON: [Int: String] = [:]

    public init() {}

    /// applies one event and returns any reply text it added
    @discardableResult
    public mutating func apply(_ event: JSONObject) throws -> String? {
        switch event["type"] as? String {
        case "message_start":
            model = (event["message"] as? JSONObject)?["model"] as? String
        case "content_block_start":
            guard let i = event["index"] as? Int, var block = event["content_block"] as? JSONObject else { return nil }
            if block["type"] as? String == "tool_use" {
                partialJSON[i] = ""
                block["input"] = JSONObject()
            }
            while blocks.count < i { blocks.append(["type": "text", "text": ""]) }
            if i < blocks.count { blocks[i] = block } else { blocks.append(block) }
            if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty { return text }
        case "content_block_delta":
            guard let i = event["index"] as? Int, i < blocks.count, let delta = event["delta"] as? JSONObject else { return nil }
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                blocks[i]["text"] = (blocks[i]["text"] as? String ?? "") + text
                return text
            case "thinking_delta":
                blocks[i]["thinking"] = (blocks[i]["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                blocks[i]["signature"] = delta["signature"] as? String
            case "input_json_delta":
                partialJSON[i, default: ""] += delta["partial_json"] as? String ?? ""
            case "citations_delta":
                if let citation = delta["citation"] {
                    blocks[i]["citations"] = (blocks[i]["citations"] as? [Any] ?? []) + [citation]
                }
            default:
                break
            }
        case "content_block_stop":
            guard let i = event["index"] as? Int, i < blocks.count, let raw = partialJSON.removeValue(forKey: i) else { return nil }
            // eager input streaming means the server does not validate tool input, so parse it strictly here
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks[i]["input"] = JSONObject()
            } else if let data = raw.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
                blocks[i]["input"] = object
            } else {
                blocks[i]["input"] = JSONObject()
                if let id = blocks[i]["id"] as? String { invalidToolInputs[id] = raw }
            }
        case "message_delta":
            if let delta = event["delta"] as? JSONObject {
                if let reason = delta["stop_reason"] as? String { stopReason = reason }
                if let details = delta["stop_details"] as? JSONObject { refusalCategory = details["category"] as? String }
            }
        case "error":
            let error = event["error"] as? JSONObject
            throw AssistantError.stream(error?["message"] as? String ?? "unknown error")
        default:
            break
        }
        return nil
    }

    /// the tool calls in this reply
    public var toolCalls: [(id: String, name: String, input: JSONObject)] {
        blocks.compactMap { b in
            guard b["type"] as? String == "tool_use", let id = b["id"] as? String, let name = b["name"] as? String else { return nil }
            return (id, name, b["input"] as? JSONObject ?? [:])
        }
    }

    /// the turn to keep in the conversation. when a declined reply was taken over by a fallback model partway,
    /// the declined model's thinking and tool calls before the last fallback marker are left out, as the api
    /// requires, and the marker stays where it was.
    public var historyContent: [JSONObject] {
        guard let boundary = blocks.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return blocks }
        let echoedBefore: Set<String> = ["text", "fallback"]
        return blocks.enumerated().compactMap { i, b in
            if i < boundary, !echoedBefore.contains(b["type"] as? String ?? "") { return nil }
            return b
        }
    }
}

/// splits a server-sent event stream into events, one `data:` line at a time
public enum SSE {
    public static func event(fromLine line: String) -> JSONObject? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }
}

// taste profile

public enum TasteProfile {
    /// the system prompt for one conversation: how to behave, then the user's ratings, watchlist, and services.
    /// it is built once when a conversation starts and never changes during it, so the cached prefix and
    /// earlier thinking blocks stay valid.
    public static func systemPrompt(reviews: [Review], watchlist: [(title: Title, status: String)],
                                    services: [String], region: String, today: String) -> String {
        var out = """
        You are the recommendation assistant inside Screenbook, a Mac app where the user tracks the movies and TV shows they want to watch and rates what they have seen. Help them decide what to watch.

        How to help:
        - Base suggestions on their ratings below. Look for patterns in what they rate high and low, and say briefly why a pick fits, citing a title they rated (for example, "you gave The Leftovers 5 stars").
        - Use search_tmdb to confirm a title exists before recommending it by name, and title_details when you need more about it. Do not invent titles, years, or plot details.
        - Before saying where something streams, call where_to_watch. When they want something to watch now, prefer titles on their services.
        - Skip things they have already rated or have on their watchlist unless they ask about them. Titles on their watchlist marked To Watch are good answers to "what should I watch tonight".
        - Call read_review when their own words about a title would help, for example to understand why they disliked something.
        - Call add_to_watchlist only when they ask to add something. The app asks them to confirm first.
        - Keep replies short: a few picks with one line each, unless they ask for more. Use plain markdown with bold titles, no tables, no headings.

        Today is \(today). Region: \(region). \(services.isEmpty ? "They have not told Screenbook which streaming services they pay for." : "Their streaming services: \(services.joined(separator: ", ")).")
        Ratings are from 0.5 to 5 stars.
        """

        let rated = reviews.filter { ($0.rating ?? 0) > 0 }
            .sorted { ($0.rating ?? 0, $0.finishedOn ?? "") > ($1.rating ?? 0, $1.finishedOn ?? "") }
        out += "\n\nTheir ratings (\(rated.count), highest first):\n"
        for r in rated {
            var line = "\(stars(r.rating)) \(r.noteTitle) (\(r.mediaType == .movie ? "movie" : "TV")"
            if let d = r.finishedOn, d.count >= 4 { line += ", \(d.prefix(4))" }
            if r.rewatch { line += ", rewatch" }
            out += line + ")\n"
        }

        out += "\nTheir watchlist (\(watchlist.count)):\n"
        for (t, status) in watchlist.sorted(by: { $0.title.title.localizedStandardCompare($1.title.title) == .orderedAscending }) {
            out += "- \(t.title) (\(t.mediaType == .movie ? "movie" : "TV")\(t.year.map { ", \($0)" } ?? "")): \(status)\n"
        }
        return out
    }

    static func stars(_ rating: Double?) -> String {
        guard let rating else { return "" }
        return String(format: rating == rating.rounded() ? "%.0f" : "%.1f", rating) + "/5"
    }
}
