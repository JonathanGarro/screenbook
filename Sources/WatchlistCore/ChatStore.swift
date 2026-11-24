import Foundation

// saved ask claude conversations. each keeps the exact system prompt and api messages it was built from,
// so reopening one continues the same conversation, plus the bubbles shown on screen. kept per device.

public struct SavedChat: Sendable, Equatable {
    public var id: String
    public var title: String
    /// true once the user renamed it, so the automatic name never replaces theirs
    public var renamed: Bool
    public var system: String
    /// the api messages as json
    public var messages: String
    /// the on-screen bubbles as json
    public var items: String
    public var createdAt: String
    public var updatedAt: String

    public init(id: String = UUID().uuidString, title: String, renamed: Bool = false, system: String,
                messages: String, items: String, createdAt: String, updatedAt: String) {
        self.id = id
        self.title = title
        self.renamed = renamed
        self.system = system
        self.messages = messages
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ChatSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: String
}

let chatSchemaSQL = """
create table if not exists chats (
    id text primary key,
    title text not null,
    renamed integer not null default 0,
    system text not null,
    messages text not null,
    items text not null,
    created_at text not null,
    updated_at text not null
);
"""

extension Database {
    public func saveChat(_ c: SavedChat) throws {
        try execute("""
            insert into chats (id, title, renamed, system, messages, items, created_at, updated_at)
            values (?, ?, ?, ?, ?, ?, ?, ?)
            on conflict(id) do update set title = excluded.title, renamed = excluded.renamed, system = excluded.system,
                messages = excluded.messages, items = excluded.items, updated_at = excluded.updated_at
            """, [.text(c.id), .text(c.title), .of(c.renamed), .text(c.system), .text(c.messages), .text(c.items),
                  .text(c.createdAt), .text(c.updatedAt)])
    }

    /// saved chats, the most recently used first
    public func chatSummaries() throws -> [ChatSummary] {
        try query("select id, title, updated_at from chats order by updated_at desc").compactMap { r in
            guard let id = r.string("id") else { return nil }
            return ChatSummary(id: id, title: r.string("title") ?? "", updatedAt: r.string("updated_at") ?? "")
        }
    }

    public func chat(_ id: String) throws -> SavedChat? {
        try query("select * from chats where id = ?", [.text(id)]).first.map { r in
            SavedChat(id: r.string("id") ?? id, title: r.string("title") ?? "", renamed: (r.int("renamed") ?? 0) != 0,
                      system: r.string("system") ?? "", messages: r.string("messages") ?? "[]", items: r.string("items") ?? "[]",
                      createdAt: r.string("created_at") ?? "", updatedAt: r.string("updated_at") ?? "")
        }
    }

    /// a name given by the user (renamed) or picked automatically (only while the user has not renamed it)
    public func renameChat(_ id: String, to title: String, byUser: Bool) throws {
        if byUser {
            try execute("update chats set title = ?, renamed = 1 where id = ?", [.text(title), .text(id)])
        } else {
            try execute("update chats set title = ? where id = ? and renamed = 0", [.text(title), .text(id)])
        }
    }

    public func deleteChat(_ id: String) throws {
        try execute("delete from chats where id = ?", [.text(id)])
    }

    public func deleteAllChats() throws {
        try execute("delete from chats")
    }
}
