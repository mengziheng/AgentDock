import AppKit
import Foundation
import AgentDockCore

@MainActor
final class AppMonitor: ObservableObject {
    struct AcceptedBatch: Identifiable {
        let id = UUID()
        let entries: [(conversation: Conversation, previousExecution: String?)]
    }
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var sources: [SourceReport] = []
    @Published private(set) var codexApps: [CodexAppSource] = [.officialCodex]
    @Published private(set) var configurationIssue: String?
    @Published private(set) var lastRefresh = Date()
    @Published private(set) var isRefreshing = false
    @Published private(set) var undoBatch: AcceptedBatch?
    @Published var notice: String?
    @Published private(set) var ledger: TrackingLedger
    var trackedConversations: [Conversation] {
        ledger.snapshots.values.sorted { $0.updatedAt > $1.updatedAt }
    }
    func count(_ category: FollowUpCategory) -> Int {
        ledger.snapshots.values.filter { $0.state.followUpCategory == category }.count
    }
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let scanner = ConversationScanner()
    private let notifier = ConversationNotifier()
    private var missedTurns = MissedTurnDetector()
    /// Categories of tracked conversations at the previous refresh; nil until the first scan sets a baseline.
    private var lastCategories: [String: FollowUpCategory]?

    init() {
        if let data = defaults.data(forKey: "AgentDock.trackingLedger"),
           let saved = try? JSONDecoder().decode(TrackingLedger.self, from: data) {
            ledger = saved
        } else { ledger = TrackingLedger() }
        notifier.onOpen = { [weak self] id in self?.open(conversationID: id) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let previousConversations = trackedConversations
        let running = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { ($0, app.launchDate ?? .distantPast) }
        }, uniquingKeysWith: { min($0, $1) })
        let scanner = scanner
        let started = Date()
        Task {
            let result = await Task.detached(priority: .utility) { scanner.scan(previousConversations: previousConversations, runningApplications: running) }.value
            ledger.observe(result.conversations, archivedIDs: result.archivedConversationIDs, authoritativeApplicationIDs: result.authoritativeApplicationIDs)
            // A turn that started and ended between two polls was never seen running.
            for item in missedTurns.missedTurns(in: result.conversations, scanStarted: started) {
                ledger.recoverMissedExecution(item)
            }
            // Orca clears live agentStatus immediately at turn completion. When its
            // durable rotating snapshot proves that a currently open terminal was
            // running between polls, recover that missed lifecycle into the workbench.
            for item in result.conversations where result.inferredCompletionIDs.contains(item.id) {
                ledger.recoverMissedExecution(item)
            }
            let recoveryKey = "AgentDock.recoverMissedSessionIDs"
            let requested = Set(defaults.stringArray(forKey: recoveryKey) ?? [])
            for item in result.conversations where requested.contains(item.sessionID) {
                ledger.recoverMissedExecution(item)
            }
            if !requested.isEmpty { defaults.set(Array(requested.subtracting(result.conversations.map(\.sessionID))), forKey: recoveryKey) }
            saveLedger()
            notifyTransitions()
            conversations = result.conversations
            sources = result.sources
            codexApps = result.codexApps
            configurationIssue = result.configurationIssue
            lastRefresh = .now
            isRefreshing = false
        }
    }
    /// Notify when a tracked conversation newly needs the user: finished, waiting for input, or in trouble.
    private func notifyTransitions() {
        let current = ledger.snapshots.mapValues { $0.state.followUpCategory }
        if let previous = lastCategories {
            for item in trackedConversations {
                let category = item.state.followUpCategory
                if category != .executing && previous[item.id] != category { notifier.post(item) }
            }
        }
        lastCategories = current
    }
    func acknowledge(_ items: [Conversation]) {
        guard !items.isEmpty else { return }
        let batch = AcceptedBatch(entries: items.map { ($0, ledger.accept($0)) })
        saveLedger()
        undoBatch = batch
        Task {
            try? await Task.sleep(for: .seconds(8))
            if undoBatch?.id == batch.id { undoBatch = nil }
        }
    }
    func undoAcknowledge() {
        guard let batch = undoBatch else { return }
        for entry in batch.entries {
            ledger.undoAccept(entry.conversation, previousExecution: entry.previousExecution)
            lastCategories?[entry.conversation.id] = entry.conversation.state.followUpCategory
        }
        undoBatch = nil
        saveLedger()
    }
    private func saveLedger() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: "AgentDock.trackingLedger") }
        let urgent = count(.awaitingInput) + count(.abnormal)
        NSApp.dockTile.badgeLabel = urgent > 0 ? "\(urgent)" : nil
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private func open(conversationID: String) {
        if let item = ledger.snapshots[conversationID] ?? conversations.first(where: { $0.id == conversationID }) { activate(item) }
    }
    /// Opens the exact conversation when the source application exposes a usable route.
    /// Sources without one fall back to activation and a copied title rather than pretending
    /// that the conversation itself was opened.
    func activate(_ conversation: Conversation) {
        let name = conversation.application.name
        if let codex = codexApps.first(where: { $0.bundleID == conversation.application.id }) {
            // Codex-compatible apps share the `codex://` scheme; address the configured handler
            // explicitly so LaunchServices cannot send the thread to a different app.
            openConversationURL(URL(string: "codex://threads/\(conversation.sessionID)")!, withBundleID: codex.handlerBundleID, fallbackPath: codex.applicationPath, applicationName: name)
        } else if conversation.application.id == TrackedApplication.devin.id {
            // This is Devin's own cascade editor resource format. Session IDs may contain
            // slashes (for example acp/devin-cli/...), which are intentionally kept as path.
            var components = URLComponents()
            components.scheme = "vscode-cascade-editor"
            components.path = "/cascade-" + conversation.sessionID
            guard let resource = components.url else {
                activateApplication(for: conversation, reason: String(localized: "Could not build a link to this conversation"))
                return
            }
            openConversationURL(resource, withBundleID: TrackedApplication.devin.bundleID, fallbackPath: "/Applications/Devin.app", applicationName: name)
        } else {
            activateApplication(for: conversation, reason: String(localized: "This app has no verified way to open a specific conversation"))
        }
    }

    private func openConversationURL(_ resourceURL: URL, withBundleID bundleID: String, fallbackPath: String?, applicationName: String) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) ?? fallbackPath.map({ URL(fileURLWithPath: $0) }),
              FileManager.default.fileExists(atPath: applicationURL.path) else {
            notice = String(localized: "\(applicationName) was not found, so the conversation cannot be opened.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([resourceURL], withApplicationAt: applicationURL, configuration: configuration) { [weak self] app, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message { self?.notice = String(localized: "Could not open the \(applicationName) conversation: \(message)") }
                else if app == nil { self?.notice = String(localized: "The app did not report a result. Look for the conversation inside the app.") }
            }
        }
    }

    private func activateApplication(for conversation: Conversation, reason: String) {
        copy(conversation.displayTitle)
        let target = conversation.application
        let fallback = target.id == TrackedApplication.orca.id ? URL(fileURLWithPath: "/Applications/Orca.app") : nil
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) ?? fallback,
              FileManager.default.fileExists(atPath: applicationURL.path) else {
            notice = String(localized: "\(target.name) was not found. The conversation title has been copied.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] app, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message { self?.notice = String(localized: "Could not open \(target.name): \(message)") }
                else if app == nil { self?.notice = String(localized: "The app did not report a launch result. The conversation title has been copied.") }
                else { self?.notice = String(localized: "\(reason). Opened the app and copied the conversation title; look for it inside the app.") }
            }
        }
    }
}
