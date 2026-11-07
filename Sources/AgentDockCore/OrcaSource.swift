import Foundation

extension ConversationScanner {
    func scanOrca(previousConversations: [Conversation], inferredCompletions: inout Set<String>) throws -> [Conversation] {
        let app = TrackedApplication.orca
        let profileRoot = support + "/orca/profiles/local-default"
        let db = try ReadOnlyDatabase(profileRoot + "/profile-state.db")
        let rows = try db.rows("SELECT domain,payload,updated_at FROM profile_state_documents WHERE domain IN ('workspaceSession','workspaceSessionsByHostId','remoteLayoutSnapshots')")
        var result: [String: Conversation] = [:]
        var remoteHistory: [String: Conversation] = [:]
        // Orca removes agentStatus as soon as a remote turn ends. Its rotating state
        // backups retain the immediately preceding `working` snapshot, allowing us to
        // recover the running -> completed transition even if an 8-second poll missed it.
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: profileRoot)) ?? [])
            .filter { $0.hasPrefix("profile-state.db.backup.") && $0.hasSuffix(".db") }
            .sorted().suffix(8)
        for name in backups {
            let path = profileRoot + "/" + name
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
            if orcaBackups[name]?.stamp != stamp {
                var agents: [String: Conversation] = [:]
                var ignored: Set<String> = []
                if let backupDB = try? ReadOnlyDatabase(path),
                   let historyRow = try? backupDB.rows("SELECT payload FROM profile_state_documents WHERE domain='remoteLayoutSnapshots'").first,
                   let historyPayload = json(historyRow["payload"]) {
                    scanOrcaRemoteAgents(historyPayload, history: [:], into: &agents, inferredCompletions: &ignored)
                }
                orcaBackups[name] = (stamp, agents)
            }
            remoteHistory.merge(orcaBackups[name]?.agents ?? [:]) { _, newer in newer }
        }
        orcaBackups = orcaBackups.filter { backups.contains($0.key) }
        // Keep observed Agent lifecycles available after Orca rotates its backups.
        for item in previousConversations where item.application.id == app.id && item.sessionID.hasPrefix("remote-agent|") {
            if let saved = remoteHistory[item.sessionID], saved.updatedAt >= item.updatedAt { continue }
            remoteHistory[item.sessionID] = item
        }
        for row in rows {
            guard let payload = json(row["payload"]) else { continue }
            if row["domain"] == "remoteLayoutSnapshots" {
                scanOrcaRemoteAgents(payload, history: remoteHistory, into: &result, inferredCompletions: &inferredCompletions)
                continue
            }
            let sessions: [[String: Any]] = row["domain"] == "workspaceSession" ? [payload] : payload.values.compactMap { $0 as? [String: Any] }
            for session in sessions {
                let sleeping = (session["sleepingAgentSessionsByPaneKey"] as? [String: [String: Any]] ?? [:]).values
                let tabs = session["tabsByWorktree"] as? [String: [[String: Any]]] ?? [:]
                for (workspace, items) in tabs {
                    for tab in items {
                        guard let vault = tab["aiVaultTitle"] as? [String: Any], let id = vault["sessionId"] as? String else { continue }
                        let sleep = sleeping.first { ($0["providerSession"] as? [String: Any])?["id"] as? String == id }
                        let milliseconds = sleep?["updatedAt"] as? Double ?? tab["createdAt"] as? Double ?? 0
                        let state: ExecutionState = sleep?["state"] as? String == "done" ? .completed : .unknown
                        let title = vault["title"] as? String ?? tab["title"] as? String ?? id
                        result[id] = Conversation(sessionID: id, application: app, title: cleanTitle(title), cwd: workspace.components(separatedBy: "::").last ?? workspace, updatedAt: Date(timeIntervalSince1970: milliseconds / 1000), state: state, evidence: state == .completed ? String(localized: "Orca saved this sleeping session as done; this is not a live signal") : String(localized: "Conversation read from Orca; its remote or unrecorded execution status cannot be confirmed"), revision: String(milliseconds))
                    }
                }
            }
        }
        return Array(result.values)
    }

    private func scanOrcaRemoteAgents(_ payload: [String: Any], history: [String: Conversation], into result: inout [String: Conversation], inferredCompletions: inout Set<String>) {
        let application = TrackedApplication.orca
        for (hostID, hostValue) in payload {
            guard let host = hostValue as? [String: Any],
                  let workspaces = host["workspaces"] as? [String: Any] else { continue }
            for (workspaceID, workspaceValue) in workspaces {
                guard let workspace = workspaceValue as? [String: Any],
                      let tabs = workspace["tabs"] as? [[String: Any]] else { continue }
                for tab in tabs {
                    let status = tab["agentStatus"] as? [String: Any]
                    let terminalHandle = status?["terminalHandle"] as? String
                        ?? tab["terminal"] as? String
                        ?? tab["ptyId"] as? String
                        ?? ""
                    guard !terminalHandle.isEmpty else { continue }
                    let id = "remote-agent|\(hostID)|\(terminalHandle)"
                    // A terminal without agentStatus is normally just a shell. It is an
                    // ended Agent turn only when a previous Orca snapshot saw the same
                    // terminal with an Agent status.
                    if status == nil {
                        guard let previous = history[id] else { continue }
                        let milliseconds = max(
                            (tab["createdAt"] as? Double ?? 0),
                            previous.updatedAt.timeIntervalSince1970 * 1000
                        )
                        let item = Conversation(
                            sessionID: id,
                            application: application,
                            title: cleanTitle(tab["customTitle"] as? String ?? tab["title"] as? String ?? previous.title),
                            cwd: previous.cwd,
                            updatedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                            state: .completed,
                            evidence: String(localized: "Orca earlier recorded this terminal agent as running; its agentStatus is now cleared while the terminal still exists, so the turn has ended"),
                            revision: previous.executionID + "|completed|\(milliseconds)",
                            projectName: previous.projectName,
                            projectEvidence: previous.projectEvidence,
                            titleEvidence: tab["customTitle"] != nil ? String(localized: "Custom title of the Orca tab") : previous.titleEvidence,
                            startedAt: previous.startedAt
                        )
                        result[id] = item
                        inferredCompletions.insert(item.id)
                        continue
                    }
                    guard let status, let rawState = status["state"] as? String else { continue }
                    let milliseconds = status["updatedAt"] as? Double
                        ?? status["stateStartedAt"] as? Double
                        ?? tab["createdAt"] as? Double
                        ?? 0
                    let executionStart = status["stateStartedAt"] as? Double ?? milliseconds
                    let title = tab["customTitle"] as? String
                        ?? tab["title"] as? String
                        ?? status["terminalTitle"] as? String
                        ?? "Orca Agent"
                    let actionRequired = title.localizedCaseInsensitiveContains("Action Required")
                    let state: ExecutionState
                    switch rawState.lowercased() {
                    case "working", "running", "executing", "busy": state = .running
                    case "waiting": state = actionRequired ? .awaitingInput : .running
                    case "done", "completed", "idle", "ready": state = .completed
                    case "failed", "error": state = .failed
                    case "interrupted", "cancelled", "canceled", "stopped": state = .interrupted
                    default: state = .unknown
                    }
                    let cwd = (status["worktreeId"] as? String ?? workspaceID)
                        .components(separatedBy: "::").last ?? workspaceID
                    let detail: String
                    switch state {
                    case .running: detail = String(localized: "Orca's remote layout snapshot reports agentStatus \(rawState): the terminal agent is running")
                    case .awaitingInput: detail = String(localized: "Orca reports agentStatus waiting and the terminal is marked Action Required: waiting for your input")
                    case .completed: detail = String(localized: "Orca's remote layout snapshot reports agentStatus \(rawState): this turn has ended")
                    case .failed: detail = String(localized: "Orca's remote layout snapshot reports agentStatus \(rawState): execution failed")
                    case .interrupted: detail = String(localized: "Orca's remote layout snapshot reports agentStatus \(rawState): execution was interrupted")
                    case .unknown: detail = String(localized: "Read an Orca remote terminal agent, but its status \(rawState) cannot be interpreted")
                    }
                    result[id] = Conversation(
                        sessionID: id,
                        application: application,
                        title: cleanTitle(title),
                        cwd: cwd,
                        updatedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                        state: state,
                        evidence: detail,
                        revision: "\(executionStart)|\(rawState)|\(milliseconds)",
                        projectName: URL(fileURLWithPath: cwd).lastPathComponent,
                        projectEvidence: String(localized: "From the worktreeId of the Orca remote agent"),
                        titleEvidence: tab["customTitle"] != nil ? String(localized: "Custom title of the Orca tab") : String(localized: "Orca remote terminal title"),
                        startedAt: Date(timeIntervalSince1970: executionStart / 1000)
                    )
                }
            }
        }
    }
}
