import Foundation
import Testing
import CSQLite
@testable import AgentDockCore

/// Builds throwaway fixture homes and databases under the temporary directory.
struct Fixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDockTests-" + UUID().uuidString).path
    init() throws { try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true) }
    func database(_ relativePath: String, _ sql: String) throws -> String {
        let path = home + "/" + relativePath
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open(path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, Comment(rawValue: String(cString: sqlite3_errmsg(db))))
        return path
    }
    func write(_ relativePath: String, _ text: String) throws {
        let path = home + "/" + relativePath
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@Suite struct SourceTests {
    @Test func missingDataProducesNoConversations() {
        let scan = ConversationScanner(home: "/nonexistent/AgentDockTests").scan()
        #expect(scan.conversations.isEmpty)
        #expect(scan.sources.count == 3 && scan.sources.allSatisfy { !$0.connected })
    }

    @Test func codexAppConfiguration() throws {
        let fixture = try Fixture()
        try fixture.write("Library/Application Support/AgentDock/codex-apps.json", #"[{"name":"Fork","bundleID":"example.fork","dataDirectory":"~/.fork","threadHandlerBundleID":"example.fork.runtime"}]"#)
        let loaded = CodexAppSource.load(home: fixture.home)
        #expect(loaded.issue == nil && loaded.apps.map(\.bundleID) == ["com.openai.codex", "example.fork"])
        #expect(loaded.apps[1].dataRoot(home: fixture.home) == fixture.home + "/.fork")
        #expect(loaded.apps[1].executorBundleID == "example.fork.runtime")
        try fixture.write("Library/Application Support/AgentDock/codex-apps.json", "{broken")
        let broken = CodexAppSource.load(home: fixture.home)
        #expect(broken.issue != nil && broken.apps.count == 1)
    }

    /// A Codex home with one thread whose turn database still says `inProgress`.
    func codexFixture(started: TimeInterval) throws -> (Fixture, rollout: String) {
        let fixture = try Fixture()
        let rollout = fixture.home + "/.codex/rollout.jsonl"
        try fixture.write(".codex/rollout.jsonl", codexEvent("task_started", at: started))
        _ = try fixture.database(".codex/state_5.sqlite", """
            CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, rollout_path TEXT, updated_at INTEGER, source TEXT, originator TEXT, archived INTEGER);
            INSERT INTO threads VALUES ('thread-1', 'Build it', '/repo', '\(rollout)', \(Int(started)), 'vscode', 'Codex Desktop', 0);
            """)
        _ = try fixture.database(".codex/thread_history_1.sqlite", """
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, status TEXT, started_at REAL, completed_at REAL, error_json TEXT, rollout_ordinal INTEGER);
            INSERT INTO thread_turns VALUES ('thread-1', 'turn-1', 'inProgress', \(started), NULL, NULL, 1);
            """)
        return (fixture, rollout)
    }
    func codexEvent(_ type: String, at time: TimeInterval) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"type":"event_msg","timestamp":"\#(iso.string(from: Date(timeIntervalSince1970: time)))","payload":{"type":"\#(type)","turn_id":"turn-1"}}"# + "\n"
    }

    @Test func codexLogGrowthIsParsedIncrementally() throws {
        let started = Date().addingTimeInterval(-120).timeIntervalSince1970.rounded()
        let (fixture, rollout) = try codexFixture(started: started)
        let scanner = ConversationScanner(home: fixture.home)
        let running = ["com.openai.codex": Date(timeIntervalSince1970: started - 600)]
        #expect(scanner.scan(runningApplications: running).conversations.first?.state == .running)
        let completion = codexEvent("task_complete", at: started + 60)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: rollout))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completion.prefix(30).utf8))
        #expect(scanner.scan(runningApplications: running).conversations.first?.state == .running, "a half-written line is not parsed yet")
        try handle.write(contentsOf: Data(completion.dropFirst(30).utf8))
        try handle.close()
        let finished = try #require(scanner.scan(runningApplications: running).conversations.first)
        #expect(finished.state == .completed && finished.updatedAt == Date(timeIntervalSince1970: started + 60))
    }

    @Test func codexRunningTurnUsesTurnStartAndAppLiveness() throws {
        let started = Date().addingTimeInterval(-120).timeIntervalSince1970.rounded()
        let (fixture, _) = try codexFixture(started: started)
        let scanner = ConversationScanner(home: fixture.home)
        let live = scanner.scan(runningApplications: ["com.openai.codex": Date(timeIntervalSince1970: started - 600)])
        let item = try #require(live.conversations.first)
        #expect(item.state == .running)
        #expect(item.startedAt == Date(timeIntervalSince1970: started))
        // Same files, served from the cache, with the app no longer running.
        #expect(scanner.scan().conversations.first?.state == .interrupted)
        #expect(scanner.scan(runningApplications: ["com.openai.codex": Date().addingTimeInterval(60)]).conversations.first?.state == .interrupted)
    }

    @Test func orcaLocalCodexTabUsesCodexTurn() throws {
        let started = Date().addingTimeInterval(-120).timeIntervalSince1970.rounded()
        let (fixture, rollout) = try codexFixture(started: started)
        let payload = #"{"tabsByWorktree":{"ws::/repo":[{"launchAgent":"codex","aiVaultTitle":{"sessionId":"thread-1","title":"Local task","agent":"codex"}}]}}"#
        _ = try fixture.database("Library/Application Support/orca/profiles/local-default/profile-state.db", """
            CREATE TABLE profile_state_documents (domain TEXT, payload TEXT, updated_at INTEGER);
            INSERT INTO profile_state_documents VALUES ('workspaceSession', '\(payload)', 0);
            """)
        let scanner = ConversationScanner(home: fixture.home)
        let unfinished = scanner.scan(runningApplications: ["com.openai.codex": .distantPast]).conversations
        #expect(unfinished.count == 1, "the Codex CLI thread appears once, under Orca")
        let item = try #require(unfinished.first)
        // No codex process has the fixture log open.
        #expect(item.application.id == TrackedApplication.orca.id && item.state == .interrupted && item.cwd == "/repo")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: rollout))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(codexEvent("task_complete", at: started + 30).utf8))
        try handle.close()
        let finished = try #require(scanner.scan().conversations.first)
        #expect(finished.state == .completed && finished.startedAt == Date(timeIntervalSince1970: started))
    }

    @Test func devinMainChainTurn() throws {
        let fixture = try Fixture()
        func node(_ session: String, _ id: Int, _ parent: Int?, _ created: Int, _ message: String) -> String {
            "INSERT INTO message_nodes (session_id,node_id,parent_node_id,chat_message,created_at) VALUES ('\(session)',\(id),\(parent.map(String.init) ?? "NULL"),'\(message)',\(created));"
        }
        let user = #"{"role":"user","content":"go","metadata":{"is_user_input":true}}"#
        let system = #"{"role":"system","content":"ctx"}"#
        let tool = #"{"role":"tool","content":"ok"}"#
        let exec = #"{"role":"assistant","content":"","tool_calls":[{"id":"a","name":"exec","arguments":{}}],"metadata":{"finish_reason":"tool_calls"}}"#
        let ask = #"{"role":"assistant","content":"","tool_calls":[{"id":"b","name":"ask_user_question","arguments":{}}],"metadata":{"finish_reason":"tool_calls"}}"#
        let reply = #"{"role":"assistant","content":"done","metadata":{"finish_reason":"stop"}}"#
        let path = try fixture.database("sessions.db", """
            CREATE TABLE message_nodes (row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, node_id INTEGER NOT NULL, parent_node_id INTEGER, chat_message TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE(session_id, node_id));
            \(node("done", 1, nil, 1000, system))\(node("done", 2, 1, 1001, user))\(node("done", 3, 2, 1002, exec))\(node("done", 4, 3, 1003, tool))\(node("done", 5, 4, 1004, reply))\(node("done", 6, 5, 1100, system))
            \(node("ask", 1, nil, 2000, user))\(node("ask", 2, 1, 2001, ask))
            \(node("next", 1, nil, 3000, user))\(node("next", 2, 1, 3001, reply))\(node("next", 3, 2, 3002, user))\(node("next", 4, 3, 3003, exec))
            """)
        let db = try ReadOnlyDatabase(path)
        let done = try #require(ConversationScanner.devinTurn(db: db, sessionID: "done", mainChainID: "6"))
        #expect(done.state(lockHeld: true) == .completed)
        #expect(done.turnNodeID == "2" && done.turnStarted == Date(timeIntervalSince1970: 1001) && done.headCreated == Date(timeIntervalSince1970: 1004))
        let waiting = try #require(ConversationScanner.devinTurn(db: db, sessionID: "ask", mainChainID: "2"))
        #expect(waiting.state(lockHeld: true) == .awaitingInput && waiting.state(lockHeld: false) == .interrupted)
        let next = try #require(ConversationScanner.devinTurn(db: db, sessionID: "next", mainChainID: "4"))
        #expect(next.state(lockHeld: true) == .running && next.turnNodeID == "3" && next.latestAssistant == Date(timeIntervalSince1970: 3003))
    }

    @Test func devinSessionsComeFromSessionStoreAndRespectArchive() throws {
        let fixture = try Fixture()
        let reply = #"{"role":"assistant","content":"done","metadata":{"finish_reason":"stop"}}"#
        _ = try fixture.database(".local/share/devin/cli/sessions.db", """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, working_directory TEXT, last_activity_at INTEGER, main_chain_id INTEGER, hidden INTEGER);
            CREATE TABLE message_nodes (row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, node_id INTEGER NOT NULL, parent_node_id INTEGER, chat_message TEXT NOT NULL, created_at INTEGER NOT NULL);
            INSERT INTO sessions VALUES ('kept', 'Kept task', '/repo', 1000, 1, 0), ('gone', 'Archived task', '/repo', 1000, NULL, 0), ('hidden', 'Hidden', '/repo', 1000, NULL, 1), ('blank', NULL, '/repo', 1000, NULL, 0);
            INSERT INTO message_nodes (session_id,node_id,parent_node_id,chat_message,created_at) VALUES ('kept', 1, NULL, '\(reply)', 1000);
            """)
        _ = try fixture.database("Library/Application Support/Devin/User/globalStorage/state.vscdb", """
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO ItemTable VALUES ('devin.desktopShell.localSessionAnnotations.org-1', '{"devin-acp/devin-cli/gone":{"archived":true},"devin-acp/devin-cli/kept":{"archived":false}}');
            """)
        let scan = ConversationScanner(home: fixture.home).scan()
        let item = try #require(scan.conversations.first)
        #expect(scan.conversations.count == 1 && item.sessionID == "acp/devin-cli/kept" && item.state == .completed)
        #expect(scan.archivedConversationIDs == [TrackedApplication.devin.id + "|acp/devin-cli/gone"])
    }

    @Test func devinRefusalSpansIncrementalReads() {
        var session: String?
        let first = ConversationScanner.providerRefusals(in: "2026-11-01T10:00:00.000Z INFO handling prompt for session quiet-fox, model x\n", session: &session)
        #expect(first.isEmpty && session == "quiet-fox")
        let second = ConversationScanner.providerRefusals(in: "2026-11-01T10:00:05.123Z WARN Provider refusal: blocked by content policy (trace ID: 1a2b3c)\n", session: &session)
        #expect(second["quiet-fox"]?.traceID == "1a2b3c")
    }
}
