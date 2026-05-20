import Foundation

/// Per-report chat history persistence. Each scan in History has a
/// unique `report.id` (UUID); we store the FollowUpChatView's
/// conversation under that key so users can reopen a past scan and
/// pick up the conversation where they left off.
///
/// Scope is intentionally narrow:
///   - FollowUpChatView (per-document chats) — persisted here.
///   - TrendsChatView + MetricChatView — still ephemeral. Those
///     chats reference a rolling Health window that changes every
///     time the user opens the tab, so a saved conversation from
///     two weeks ago would be referring to data that no longer
///     exists.
///
/// Storage is local-only — same UserDefaults bucket the rest of the
/// app uses. Chat content never leaves the device.
///
/// Cleanup is hooked into `LocalStorageService.deleteReport`: when
/// a scan is removed from History, its chat is removed too — no
/// orphan conversations lingering for reports the user no longer
/// has.
struct PersistedChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date

    enum Role: String, Codable {
        case user
        case ai
    }

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Namespace for the chat-history store. Modeled as an `enum`
/// (uninstantiable) with `static` methods because the service has
/// no instance state — everything goes through UserDefaults, which
/// is globally thread-safe. The previous singleton-class shape
/// tripped Swift 6 strict concurrency ("'shared' is not
/// concurrency-safe because non-'Sendable' type may have shared
/// mutable state"); an enum sidesteps the Sendable requirement
/// because there's no instance to share in the first place.
enum ChatHistoryService {
    /// UserDefaults bucket. Stored as `[UUID-string: [PersistedChatMessage]]`
    /// so a single decode pulls every report's chat at once — fine
    /// at app scale (hundreds of reports × dozens of messages each
    /// is still tens of KB).
    private static let storageKey = "localabs_chat_history"

    /// Loads the conversation for `reportID`, or returns an empty
    /// array if the user has never chatted about that report.
    static func messages(for reportID: UUID) -> [PersistedChatMessage] {
        loadAll()[reportID.uuidString] ?? []
    }

    /// Replaces the saved chat for `reportID` with `messages`.
    /// Called after every turn in FollowUpChatView so the on-disk
    /// copy is always current — if the app gets killed mid-stream,
    /// the conversation up to the last complete turn survives.
    static func save(_ messages: [PersistedChatMessage], for reportID: UUID) {
        var all = loadAll()
        all[reportID.uuidString] = messages
        persist(all)
    }

    /// Drops the chat for `reportID`. Hooked into
    /// `LocalStorageService.deleteReport` so deleting a scan from
    /// History also removes its chat — no orphan conversations.
    static func clear(for reportID: UUID) {
        var all = loadAll()
        all.removeValue(forKey: reportID.uuidString)
        persist(all)
    }

    // MARK: - Storage internals

    private static func loadAll() -> [String: [PersistedChatMessage]] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [PersistedChatMessage]].self, from: data)) ?? [:]
    }

    private static func persist(_ all: [String: [PersistedChatMessage]]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
