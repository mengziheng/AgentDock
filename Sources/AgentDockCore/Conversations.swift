import Foundation
import CSQLite

public enum ExecutionState: String, Codable, CaseIterable, Sendable {
    case running, awaitingInput, completed, failed, interrupted, unknown
    public var title: String {
        switch self {
        case .running: String(localized: "Running")
        case .awaitingInput: String(localized: "Needs input")
        case .completed: String(localized: "Turn complete")
        case .failed: String(localized: "Failed")
        case .interrupted: String(localized: "Interrupted")
        case .unknown: String(localized: "Status unclear")
        }
    }
    public var symbol: String {
        switch self {
        case .running: "bolt.fill"
        case .awaitingInput: "questionmark.bubble.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .interrupted: "pause.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
    public init(raw: String) {
        switch raw {
        case "inProgress": self = .running
        case "awaitingInput": self = .awaitingInput
        case "completed", "done": self = .completed
        case "failed": self = .failed
        case "interrupted": self = .interrupted
        default: self = .unknown
        }
    }
    /// An unfinished turn is live only while the app that executes it has been running since
    /// before the turn's latest activity. Silence alone never demotes a turn: long tool calls
    /// legitimately write nothing for a long time.
    public static func liveness(raw: String, lastActivity: Date, processLaunch: Date?) -> Self {
        let state = Self(raw: raw)
        guard state == .running || state == .awaitingInput else { return state }
        guard let processLaunch, processLaunch <= lastActivity else { return .interrupted }
        return state
    }
}

public struct Conversation: Identifiable, Codable, Sendable {
    public let sessionID: String
    public let application: TrackedApplication
    public let title: String
    public let cwd: String
    public let updatedAt: Date
    public let state: ExecutionState
    public let evidence: String
    public let revision: String
    public let projectName: String
    public let projectEvidence: String
    public let titleEvidence: String
    public let openingMessage: String
    /// Start of the current turn, when the source records it.
    public let startedAt: Date?
    public init(sessionID: String, application: TrackedApplication, title: String, cwd: String, updatedAt: Date, state: ExecutionState, evidence: String, revision: String, projectName: String = String(localized: "Project not identified"), projectEvidence: String = String(localized: "The source only provides a working directory, not a project"), titleEvidence: String = String(localized: "Conversation title saved by the source app"), openingMessage: String = "", startedAt: Date? = nil) {
        self.sessionID = sessionID; self.application = application; self.title = title; self.cwd = cwd
        self.updatedAt = updatedAt; self.state = state; self.evidence = evidence; self.revision = revision
        self.projectName = projectName; self.projectEvidence = projectEvidence
        self.titleEvidence = titleEvidence; self.openingMessage = openingMessage; self.startedAt = startedAt
    }
    public var id: String { application.id + "|" + sessionID }
    func with(state: ExecutionState, evidence: String) -> Conversation {
        Conversation(sessionID: sessionID, application: application, title: title, cwd: cwd, updatedAt: updatedAt, state: state, evidence: evidence, revision: revision, projectName: projectName, projectEvidence: projectEvidence, titleEvidence: titleEvidence, openingMessage: openingMessage, startedAt: startedAt)
    }
}
public struct SourceReport: Identifiable, Sendable {
    public let application: TrackedApplication
    public let detail: String
    public let connected: Bool
    public var id: String { application.id }
}
public struct ScanResult: Sendable {
    public let conversations: [Conversation]
    public let sources: [SourceReport]
    public let archivedConversationIDs: Set<String>
    /// Sources successfully read during this scan. Missing rows are authoritative only for these apps.
    public let authoritativeApplicationIDs: Set<String>
    /// Conversations whose finished execution was inferred from history the 8-second poll may have missed.
    public let inferredCompletionIDs: Set<String>
    public let codexApps: [CodexAppSource]
    public let configurationIssue: String?
}

final class ReadOnlyDatabase {
    private var db: OpaquePointer?
    init(_ path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw NSError(domain: "AgentDock", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local database is not readable"])
        }
        sqlite3_busy_timeout(db, 200)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, values: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "AgentDock", code: 2) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            _ = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var output: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw NSError(domain: "AgentDock", code: 3) }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(cString: value)
                }
            }
            output.append(row)
        }
    }
}

/// Reads every source's local storage. Results that depend only on unchanged files are cached
/// between scans; `scan` serializes access to those caches.
public final class ConversationScanner: @unchecked Sendable {
    public let home: String
    private let lock = NSLock()
    private var codexTurns: [String: (stamp: String, turn: CodexTurn)] = [:]
    var rolloutCursors: [String: RolloutCursor] = [:]
    /// Rollout logs of Codex CLI threads behind Orca tabs in the current scan; Orca is scanned first.
    var orcaCodexPaths: Set<String> = []
    var devinTurns: [String: (stamp: String, turn: DevinTurn)] = [:]
    var devinLogs: [String: DevinLogCursor] = [:]
    var orcaBackups: [String: (stamp: Date, agents: [String: Conversation])] = [:]

    public init(home: String = NSHomeDirectory()) { self.home = home }
    var support: String { home + "/Library/Application Support" }

    /// - Parameter runningApplications: bundle ID → launch date of currently running apps.
    public func scan(previousConversations: [Conversation] = [], runningApplications: [String: Date] = [:]) -> ScanResult {
        lock.lock()
        defer { lock.unlock() }
        var conversations: [Conversation] = []
        var sources: [SourceReport] = []
        var archivedIDs: Set<String> = []
        var authoritativeIDs: Set<String> = []
        var inferred: Set<String> = []
        var orca: [Conversation] = []
        do {
            orca = try scanOrca(previousConversations: previousConversations, inferredCompletions: &inferred)
            authoritativeIDs.insert(TrackedApplication.orca.id)
            sources.append(.init(application: .orca, detail: String(localized: "Connected: conversations and remote terminal agent status"), connected: true))
        } catch {
            sources.append(.init(application: .orca, detail: String(localized: "Not connected: session store is not readable"), connected: false))
        }
        let orcaIDs = Set(orca.map(\.sessionID))
        let (codexApps, issue) = CodexAppSource.load(home: home)
        for source in codexApps {
            let app = source.application
            let root = source.dataRoot(home: home)
            do {
                let db = try ReadOnlyDatabase(root + "/state_5.sqlite")
                let archived = try db.rows("SELECT id FROM threads WHERE archived=1 AND source='vscode' AND originator='Codex Desktop'")
                archivedIDs.formUnion(archived.compactMap { row in row["id"].map { app.id + "|" + $0 } })
                conversations += try scanCodex(db: db, root: root, source: source, processLaunch: runningApplications[source.executorBundleID])
                    .filter { !orcaIDs.contains($0.sessionID) && !$0.cwd.hasPrefix(home + "/orca/") }
                authoritativeIDs.insert(app.id)
                sources.append(.init(application: app, detail: String(localized: "Connected: conversations and turn status"), connected: true))
            } catch {
                sources.append(.init(application: app, detail: String(localized: "Not connected: database missing or format changed"), connected: false))
            }
        }
        conversations += orca
        do {
            let devin = try scanDevin()
            conversations += devin.conversations
            archivedIDs.formUnion(devin.archivedIDs)
            authoritativeIDs.insert(TrackedApplication.devin.id)
            sources.append(.init(application: .devin, detail: String(localized: "Connected: conversations, turn status, and provider refusals"), connected: true))
        } catch {
            sources.append(.init(application: .devin, detail: String(localized: "Not connected: session store is not readable"), connected: false))
        }
        return ScanResult(conversations: conversations.sorted { $0.updatedAt > $1.updatedAt }, sources: sources.sorted { $0.application.name < $1.application.name }, archivedConversationIDs: archivedIDs, authoritativeApplicationIDs: authoritativeIDs, inferredCompletionIDs: inferred, codexApps: codexApps, configurationIssue: issue)
    }

    struct CodexTurn {
        var raw: String
        var updated: Date
        var turnID: String
        var error: String?
        var startedAt: Date?
        var usedLog: Bool
        var modified: Date
    }

    private func scanCodex(db: ReadOnlyDatabase, root: String, source: CodexAppSource, processLaunch: Date?) throws -> [Conversation] {
        let app = source.application
        let history = try? ReadOnlyDatabase(root + "/thread_history_1.sqlite")
        let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
        let optional = ["name", "project_id"].filter { columns.contains($0) }
        let fields = (["id", "title", "cwd", "rollout_path", "updated_at"] + optional).joined(separator: ",")
        let rows = try db.rows("SELECT \(fields) FROM threads WHERE source='vscode' AND originator='Codex Desktop' AND archived=0 ORDER BY updated_at DESC LIMIT 500")
        let catalog = projectCatalog(root: root, db: db)
        var seen: Set<String> = []
        var paths: Set<String> = []
        let result = rows.map { row in
            let id = row["id"] ?? ""
            let path = row["rollout_path"] ?? ""
            paths.insert(path)
            let key = root + "|" + id
            seen.insert(key)
            let turn = cachedCodexTurn(key: key, row: row, history: history)
            let lastActivity = max(turn.updated, turn.modified)
            let state = ExecutionState.liveness(raw: turn.raw, lastActivity: lastActivity, processLaunch: processLaunch)
            let abandoned = state == .interrupted && turn.raw != "interrupted"
            let origin = turn.usedLog ? String(localized: "From the rollout log, which is newer than the turn database") : String(localized: "From the latest turn database record")
            let reading: String
            switch state {
            case .awaitingInput: reading = String(localized: "The agent asked a question that has no answer yet; waiting for you")
            case .running: reading = String(localized: "The turn has not finished and \(app.name) is running")
            case .interrupted where abandoned: reading = String(localized: "The turn never finished and \(app.name) has quit or restarted since its last activity")
            case .completed: reading = String(localized: "This turn finished; the overall task may still need follow-up")
            case .unknown: reading = String(localized: "The log changed after the last turn record, but no turn event could be read")
            case .failed, .interrupted: reading = String(localized: "The turn ended with an error or was stopped")
            }
            let detail = origin + "; " + reading + (turn.error.map { "; " + String(localized: "Error: \($0)") } ?? "")
            let name = row["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = row["title"] ?? ""
            let project = catalog.resolve(sessionID: id, projectID: row["project_id"], cwd: row["cwd"] ?? "")
            return Conversation(sessionID: id, application: app, title: cleanTitle(name.isEmpty ? (message.isEmpty ? String(localized: "Untitled conversation") : message) : name), cwd: row["cwd"] ?? "", updatedAt: state == .running ? lastActivity : turn.updated, state: state, evidence: detail, revision: turn.turnID + "|" + state.rawValue, projectName: project.name, projectEvidence: project.evidence, titleEvidence: name.isEmpty ? String(localized: "The source saved no conversation name; showing the first message") : String(localized: "Conversation name saved by the app"), openingMessage: message, startedAt: turn.startedAt)
        }
        pruneCodexTurns(prefix: root + "|", keeping: seen)
        rolloutCursors = rolloutCursors.filter { !$0.key.hasPrefix(root + "/") || paths.contains($0.key) || orcaCodexPaths.contains($0.key) }
        return result
    }

    /// Latest turn of a Codex thread row (`id`, `rollout_path`, `updated_at`), re-read only when the row or its log changed.
    func cachedCodexTurn(key: String, row: [String: String], history: ReadOnlyDatabase?) -> CodexTurn {
        let path = row["rollout_path"] ?? ""
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date
        let stamp = "\(row["updated_at"] ?? "")|\(modified?.timeIntervalSince1970 ?? 0)|\(attributes?[.size] as? UInt64 ?? 0)"
        if let cached = codexTurns[key], cached.stamp == stamp { return cached.turn }
        let read = readCodexTurn(id: row["id"] ?? "", row: row, path: path, modified: modified, history: history)
        // A busy or unreadable turn database is transient: keep the previous result
        // for this scan and retry on the next one.
        if read.complete { codexTurns[key] = (stamp, read.turn) }
        return read.complete ? read.turn : codexTurns[key]?.turn ?? read.turn
    }

    /// Drops cached Codex turns under `prefix` that were not read in this scan.
    func pruneCodexTurns(prefix: String, keeping seen: Set<String>) {
        for key in codexTurns.keys where key.hasPrefix(prefix) && !seen.contains(key) { codexTurns.removeValue(forKey: key) }
    }

    private func readCodexTurn(id: String, row: [String: String], path: String, modified: Date?, history: ReadOnlyDatabase?) -> (turn: CodexTurn, complete: Bool) {
        var complete = history != nil
        let record: [String: String]?
        do { record = try history?.rows("SELECT turn_id,status,started_at,completed_at,error_json FROM thread_turns WHERE thread_id=? ORDER BY rollout_ordinal DESC LIMIT 1", values: [id]).first }
        catch { record = nil; complete = false }
        var turn = CodexTurn(raw: record?["status"] ?? "unknown", updated: .distantPast, turnID: record?["turn_id"] ?? "unknown", error: nil, startedAt: record?["started_at"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }, usedLog: false, modified: .distantPast)
        if let data = record?["error_json"]?.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            turn.error = RolloutLifecycle.errorSummary(value)
            if turn.error != nil { turn.raw = "failed" }
        }
        turn.updated = Date(timeIntervalSince1970: Double(record?["completed_at"] ?? record?["started_at"] ?? row["updated_at"] ?? "0") ?? 0)
        turn.modified = modified ?? turn.updated
        // The turn database can lag behind the rollout log; prefer newer log events.
        if turn.modified.timeIntervalSince(turn.updated) > 1 || record == nil || turn.raw == "inProgress" {
            if let event = RolloutCursor.read(path: path, cursor: &rolloutCursors[path]), event.timestamp >= turn.updated {
                turn.startedAt = event.startedAt ?? (event.turnID == turn.turnID ? turn.startedAt : nil)
                turn.raw = event.status; turn.updated = event.timestamp; turn.turnID = event.turnID; turn.usedLog = true; turn.error = event.errorSummary
            } else if turn.modified.timeIntervalSince(turn.updated) > 600 && turn.raw != "inProgress" {
                turn.raw = "unknown"
            }
        }
        return (turn, complete)
    }

    private func projectCatalog(root: String, db: ReadOnlyDatabase) -> ProjectCatalog {
        var catalog = ProjectCatalog()
        // Decode locally, retain only project metadata; never log or expose other global state.
        if let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/.codex-global-state.json")),
           let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let projects = state["local-projects"] as? [String: [String: Any]] ?? [:]
            for (id, value) in projects {
                if let name = value["name"] as? String, !name.isEmpty {
                    catalog.projects[id] = .init(name: name, roots: value["rootPaths"] as? [String] ?? [])
                }
            }
            let assignments = state["thread-project-assignments"] as? [String: [String: Any]] ?? [:]
            for (id, value) in assignments { catalog.assignments[id] = value["projectId"] as? String }
            catalog.projectless = Set(state["projectless-thread-ids"] as? [String] ?? [])
        }
        let roots = (try? db.rows("SELECT project_id,path FROM project_roots ORDER BY position")) ?? []
        for row in (try? db.rows("SELECT id,name FROM projects")) ?? [] {
            if let id = row["id"], let name = row["name"], !name.isEmpty {
                catalog.projects[id] = .init(name: name, roots: roots.filter { $0["project_id"] == id }.compactMap { $0["path"] })
            }
        }
        return catalog
    }
    func json(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func cleanTitle(_ text: String) -> String {
        let cleaned = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(cleaned.prefix(240))
    }
}
