import Foundation
import Darwin

/// The latest turn on a Devin session's main message chain.
struct DevinTurn: Equatable, Sendable {
    /// Last non-system message on the main chain.
    var headRole: String?
    var headToolNames: [String] = []
    var headFinishReason: String?
    var headCreated: Date?
    var latestAssistant: Date?
    /// Latest user message on the main chain; identifies the turn.
    var turnNodeID: String?
    var turnStarted: Date?

    /// Devin's long-lived `devin acp` process keeps the lock of every session it has opened,
    /// so the lock only proves that a live process could still be working on the turn.
    /// Whether the turn has ended comes from the main chain itself.
    func state(lockHeld: Bool) -> ExecutionState {
        guard let headRole else { return .unknown }
        if headRole == "assistant" && headToolNames.isEmpty && headFinishReason != "max_tokens" { return .completed }
        guard lockHeld else { return .interrupted }
        return headToolNames.contains("ask_user_question") ? .awaitingInput : .running
    }
}

struct DevinProviderRefusal: Equatable, Sendable {
    let date: Date
    let traceID: String?
}

/// Read position in one Devin log, so each scan parses only newly appended lines.
struct DevinLogCursor {
    var offset: UInt64 = 0
    var session: String?
    var refusals: [String: DevinProviderRefusal] = [:]
}

extension ConversationScanner {
    /// Devin's own session store lists the conversations; the desktop app only adds archive flags.
    func scanDevin() throws -> (conversations: [Conversation], archivedIDs: Set<String>) {
        let app = TrackedApplication.devin
        let cliRoot = home + "/.local/share/devin/cli"
        let cliDB = try ReadOnlyDatabase(cliRoot + "/sessions.db")
        let rows = try cliDB.rows("SELECT id,title,working_directory,last_activity_at,main_chain_id FROM sessions WHERE hidden=0")
        let annotations = devinSessionAnnotations()
        let refusals = latestDevinProviderRefusals(logRoot: cliRoot + "/logs")
        var seen: Set<String> = []
        var archived: Set<String> = []
        let result = rows.compactMap { cli -> Conversation? in
            guard let localID = cli["id"], let title = cli["title"], !title.isEmpty else { return nil }
            // Same identifier the desktop app uses, so its deep link and earlier tracking records still match.
            let id = "acp/devin-cli/" + localID
            let annotation = annotations["devin-acp/devin-cli/" + localID]
            if annotation?["archived"] as? Bool == true {
                archived.insert(app.id + "|" + id)
                return nil
            }
            var turn = DevinTurn()
            if let chainID = cli["main_chain_id"] {
                let stamp = (cli["last_activity_at"] ?? "") + "|" + chainID
                seen.insert(localID)
                if let cached = devinTurns[localID], cached.stamp == stamp {
                    turn = cached.turn
                } else if let read = Self.devinTurn(db: cliDB, sessionID: localID, mainChainID: chainID) {
                    turn = read
                    devinTurns[localID] = (stamp, turn)
                } else {
                    // A busy session store is transient: keep the previous result and retry next scan.
                    turn = devinTurns[localID]?.turn ?? turn
                }
            }
            let lastActivity = cli["last_activity_at"] ?? ""
            let cliDate = Date(timeIntervalSince1970: Double(lastActivity) ?? 0)
            // A refusal is resolved by a later assistant reply or by a new user turn.
            let refusal = refusals[localID].flatMap { $0.date >= max(turn.latestAssistant ?? .distantPast, turn.turnStarted ?? .distantPast) ? $0 : nil }
            let lockHeld = devinLockIsHeld(path: cliRoot + "/session_locks/" + localID + ".lock")
            let state = refusal != nil ? .failed : turn.state(lockHeld: lockHeld)
            let evidence: String
            switch state {
            case .failed: evidence = String(localized: "Devin returned ContentFilter: the model provider refused the request and it cannot be retried as is. Switch models or adjust the request.") + (refusal?.traceID.map { " " + String(localized: "Trace ID: \($0)") } ?? "")
            case .running: evidence = String(localized: "Devin is still working on this conversation and has not given a final reply for this turn")
            case .awaitingInput: evidence = String(localized: "Devin asked a question and is waiting for your answer")
            case .completed: evidence = String(localized: "Devin gave its final reply for this turn; the overall task may still need follow-up")
            case .interrupted: evidence = String(localized: "The turn has no final reply and Devin is no longer working on this conversation")
            case .unknown: evidence = String(localized: "No conversation turn was found in Devin's local session store")
            }
            let activity = max(cliDate, refusal?.date ?? .distantPast)
            let errorRevision = refusal.map { "|content_filter|" + String($0.date.timeIntervalSince1970) } ?? ""
            return Conversation(sessionID: id, application: app, title: cleanTitle(title), cwd: cli["working_directory"] ?? "", updatedAt: state == .completed ? (turn.headCreated ?? activity) : activity, state: state, evidence: evidence, revision: (turn.turnNodeID ?? lastActivity) + "|" + state.rawValue + errorRevision, startedAt: turn.turnStarted)
        }
        devinTurns = devinTurns.filter { seen.contains($0.key) }
        return (result, archived)
    }

    /// Per-session flags (`archived`, `done`, ...) that the Devin desktop app keeps for each account.
    private func devinSessionAnnotations() -> [String: [String: Any]] {
        guard let db = try? ReadOnlyDatabase(support + "/Devin/User/globalStorage/state.vscdb"),
              let rows = try? db.rows("SELECT value FROM ItemTable WHERE key LIKE 'devin.desktopShell.localSessionAnnotations.%'") else { return [:] }
        var merged: [String: [String: Any]] = [:]
        for row in rows {
            for (key, value) in json(row["value"]) ?? [:] {
                guard let flags = value as? [String: Any] else { continue }
                merged[key, default: [:]].merge(flags) { first, second in (first as? Bool == true || second as? Bool == true) ? true : second }
            }
        }
        return merged
    }

    /// Walks the main chain from its head back to the latest user message; nil when the store cannot be read.
    static func devinTurn(db: ReadOnlyDatabase, sessionID: String, mainChainID: String) -> DevinTurn? {
        guard let chain = try? db.rows("""
            WITH RECURSIVE chain(node_id, parent, role, ui, created, depth) AS (
              SELECT node_id, parent_node_id, json_extract(chat_message,'$.role'), json_extract(chat_message,'$.metadata.is_user_input'), created_at, 0
              FROM message_nodes WHERE session_id=?1 AND node_id=?2 AND json_valid(chat_message)
              UNION ALL
              SELECT m.node_id, m.parent_node_id, json_extract(m.chat_message,'$.role'), json_extract(m.chat_message,'$.metadata.is_user_input'), m.created_at, c.depth + 1
              FROM message_nodes m JOIN chain c ON m.session_id=?1 AND m.node_id=c.parent
              WHERE c.ui IS NOT 1 AND c.depth < 20000 AND json_valid(m.chat_message)
            )
            SELECT node_id, role, ui, created FROM chain ORDER BY depth
            """, values: [sessionID, mainChainID]) else { return nil }
        var turn = DevinTurn()
        var headNode: String?
        for row in chain {
            let role = row["role"]
            let created = Double(row["created"] ?? "").map { Date(timeIntervalSince1970: $0) }
            if headNode == nil, let role, role != "system" {
                headNode = row["node_id"]; turn.headRole = role; turn.headCreated = created
            }
            if turn.latestAssistant == nil, role == "assistant" { turn.latestAssistant = created }
            if row["ui"] == "1" { turn.turnNodeID = row["node_id"]; turn.turnStarted = created }
        }
        if let headNode, turn.headRole == "assistant" {
            guard let head = try? db.rows("SELECT json_extract(chat_message,'$.metadata.finish_reason') AS finish, (SELECT group_concat(json_extract(value,'$.name'), char(31)) FROM json_each(json_extract(chat_message,'$.tool_calls'))) AS tools FROM message_nodes WHERE session_id=?1 AND node_id=?2", values: [sessionID, headNode]) else { return nil }
            turn.headFinishReason = head.first?["finish"]
            turn.headToolNames = head.first?["tools"]?.split(separator: "\u{1F}").map(String.init) ?? []
        }
        return turn
    }

    static func providerRefusals(in text: String, session: inout String?) -> [String: DevinProviderRefusal] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [String: DevinProviderRefusal] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let range = line.range(of: " for session ") {
                let id = line[range.upperBound...].prefix { !$0.isWhitespace && $0 != "," }
                if !id.isEmpty { session = String(id) }
            }
            guard line.localizedCaseInsensitiveContains("Provider refusal"),
                  line.localizedCaseInsensitiveContains("content policy"),
                  let session else { continue }
            let stamp = String(line.prefix(while: { !$0.isWhitespace }))
            guard let date = iso.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { continue }
            var traceID: String?
            if let start = line.range(of: "trace ID: ", options: .caseInsensitive) {
                let value = line[start.upperBound...].prefix { $0.isHexDigit }
                if !value.isEmpty { traceID = String(value) }
            }
            merge(&result, [session: DevinProviderRefusal(date: date, traceID: traceID)])
        }
        return result
    }

    private static func merge(_ target: inout [String: DevinProviderRefusal], _ other: [String: DevinProviderRefusal]) {
        for (session, refusal) in other where target[session]?.date ?? .distantPast < refusal.date { target[session] = refusal }
    }

    private func latestDevinProviderRefusals(logRoot: String) -> [String: DevinProviderRefusal] {
        let manager = FileManager.default
        let files = ((try? manager.contentsOfDirectory(atPath: logRoot)) ?? [])
            .filter { $0.hasPrefix("devin_") && $0.hasSuffix(".log") }
            .compactMap { name -> (String, Date)? in
                let path = logRoot + "/" + name
                let date = (try? manager.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
                return Date().timeIntervalSince(date) < 7 * 86400 ? (path, date) : nil
            }
            .sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
        let window: UInt64 = 4 * 1024 * 1024
        var result: [String: DevinProviderRefusal] = [:]
        for path in files {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            var cursor = devinLogs[path] ?? DevinLogCursor()
            var skipPartialLine = false
            // Start over on first sight, truncation, or growth beyond the read window.
            if devinLogs[path] == nil || size < cursor.offset || size - cursor.offset > window {
                cursor = DevinLogCursor(offset: size > window ? size - window : 0)
                skipPartialLine = cursor.offset > 0
            }
            if size > cursor.offset, (try? handle.seek(toOffset: cursor.offset)) != nil,
               let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 10) {
                // Consume complete lines only; a partially written line is read next time.
                var chunk = data[data.startIndex...lastNewline]
                if skipPartialLine, let first = chunk.firstIndex(of: 10) { chunk = chunk[chunk.index(after: first)...] }
                if let text = String(data: chunk, encoding: .utf8) {
                    Self.merge(&cursor.refusals, Self.providerRefusals(in: text, session: &cursor.session))
                }
                cursor.offset += UInt64(lastNewline - data.startIndex + 1)
            }
            devinLogs[path] = cursor
            Self.merge(&result, cursor.refusals)
        }
        devinLogs = devinLogs.filter { files.contains($0.key) }
        return result
    }

    private func devinLockIsHeld(path: String) -> Bool {
        let descriptor = open(path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
