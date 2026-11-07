import Foundation

/// Track execution lifecycles, not a rolling window of chat history.
public struct TrackingLedger: Codable, Sendable {
    public private(set) var tracked: Set<String> = []
    public private(set) var acceptedExecutions: [String: String] = [:]
    public private(set) var snapshots: [String: Conversation] = [:]
    public init() {}
    public mutating func observe(_ conversations: [Conversation], archivedIDs: Set<String> = [], authoritativeApplicationIDs: Set<String>? = nil) {
        for id in archivedIDs {
            if let item = snapshots[id] { acceptedExecutions[id] = item.executionID }
            tracked.remove(id)
            snapshots.removeValue(forKey: id)
        }
        let visibleIDs = Set(conversations.map(\.id))
        for (id, item) in snapshots where !visibleIDs.contains(id) && (item.state == .running || item.state == .awaitingInput) {
            // A failed scan says nothing about task state. Preserve the last known
            // value; only a successfully read source can authoritatively report absence.
            // Finished conversations that the user closed in the source keep their final state.
            if let authoritativeApplicationIDs, !authoritativeApplicationIDs.contains(item.application.id) { continue }
            snapshots[id] = item.with(state: .unknown, evidence: String(localized: "The source no longer lists this conversation while it was still active; the last record is kept until you accept it"))
        }
        for item in conversations where !archivedIDs.contains(item.id) {
            if (item.state == .running || item.state == .awaitingInput) && acceptedExecutions[item.id] != item.executionID { tracked.insert(item.id) }
            if tracked.contains(item.id) { snapshots[item.id] = item }
        }
    }
    public mutating func recoverMissedExecution(_ item: Conversation) {
        guard acceptedExecutions[item.id] != item.executionID else { return }
        tracked.insert(item.id)
        snapshots[item.id] = item
    }
    /// Returns the previously accepted execution so the acceptance can be undone.
    @discardableResult
    public mutating func accept(_ item: Conversation) -> String? {
        tracked.remove(item.id)
        snapshots.removeValue(forKey: item.id)
        let previous = acceptedExecutions[item.id]
        acceptedExecutions[item.id] = item.executionID
        return previous
    }
    public mutating func undoAccept(_ item: Conversation, previousExecution: String?) {
        tracked.insert(item.id)
        snapshots[item.id] = item
        acceptedExecutions[item.id] = previousExecution
    }
    public func contains(_ item: Conversation) -> Bool { tracked.contains(item.id) }
}

/// Finds turns that started and ended between two scans, so the ledger never saw them running.
public struct MissedTurnDetector: Sendable {
    private var executions: [String: String]?
    private var lastScan: Date?
    public init() {}
    /// Conversations whose turn changed since the previous scan and already ended after that scan
    /// started. The first call only records a baseline, so history is never imported.
    public mutating func missedTurns(in conversations: [Conversation], scanStarted: Date) -> [Conversation] {
        defer {
            executions = Dictionary(conversations.map { ($0.id, $0.executionID) }, uniquingKeysWith: { first, _ in first })
            lastScan = scanStarted
        }
        guard let executions, let lastScan else { return [] }
        return conversations.filter { item in
            item.state != .running && item.state != .unknown && executions[item.id] != item.executionID && item.updatedAt >= lastScan
        }
    }
}

extension Conversation {
    public var executionID: String { revision.components(separatedBy: "|").first ?? revision }
}
