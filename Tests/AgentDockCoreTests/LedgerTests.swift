import Foundation
import Testing
@testable import AgentDockCore

@Suite struct LedgerTests {
    let app = CodexAppSource.officialCodex.application
    func execution(_ turn: String, _ state: ExecutionState) -> Conversation {
        Conversation(sessionID: "tracked", application: app, title: "Task", cwd: "", updatedAt: Date(timeIntervalSince1970: 100_000), state: state, evidence: "fixture", revision: turn + "|" + state.rawValue)
    }

    @Test func lifecycleFromRunningToAccepted() throws {
        var ledger = TrackingLedger()
        let active = execution("turn-1", .running)
        let finished = execution("turn-1", .completed)
        ledger.observe([finished])
        #expect(!ledger.contains(finished), "historical completions are not imported")
        ledger.observe([active])
        #expect(ledger.contains(active))
        ledger.observe([finished])
        #expect(ledger.snapshots[finished.id]?.state == .completed)
        ledger = try JSONDecoder().decode(TrackingLedger.self, from: JSONEncoder().encode(ledger))
        #expect(ledger.contains(finished), "survives restart")
        ledger.accept(finished)
        ledger.observe([active])
        #expect(!ledger.contains(active), "an accepted turn is not added again")
        ledger.observe([execution("turn-2", .running)])
        #expect(ledger.contains(active), "a new turn is added again")
    }

    @Test func disappearedConversationKeepsFinalStateButActiveOneBecomesUnclear() {
        var ledger = TrackingLedger()
        ledger.observe([execution("turn-1", .running)])
        ledger.observe([execution("turn-1", .completed)])
        ledger.observe([], authoritativeApplicationIDs: [app.id])
        #expect(ledger.snapshots[app.id + "|tracked"]?.state == .completed)

        var active = TrackingLedger()
        active.observe([execution("turn-1", .running)])
        active.observe([], authoritativeApplicationIDs: [])
        #expect(active.snapshots[app.id + "|tracked"]?.state == .running, "an unreadable source proves nothing")
        active.observe([], authoritativeApplicationIDs: [app.id])
        #expect(active.snapshots[app.id + "|tracked"]?.state == .unknown)
    }

    @Test func archivedConversationIsRemoved() {
        var ledger = TrackingLedger()
        let active = execution("turn-1", .running)
        ledger.observe([active])
        ledger.observe([], archivedIDs: [active.id])
        #expect(!ledger.contains(active) && ledger.snapshots[active.id] == nil)
        ledger.observe([active])
        #expect(!ledger.contains(active))
        ledger.observe([execution("turn-2", .running)])
        #expect(ledger.contains(active))
    }

    @Test func undoRestoresTrackingAndPreviousAcceptance() {
        var ledger = TrackingLedger()
        ledger.observe([execution("turn-1", .running)])
        let finished = execution("turn-1", .completed)
        ledger.observe([finished])
        let previous = ledger.accept(finished)
        #expect(previous == nil && !ledger.contains(finished))
        ledger.undoAccept(finished, previousExecution: previous)
        #expect(ledger.contains(finished) && ledger.snapshots[finished.id]?.state == .completed)
        ledger.observe([execution("turn-1", .running)])
        #expect(ledger.contains(finished), "after undo the turn is tracked as before")
    }

    @Test func shortTurnBetweenScansIsDetected() {
        var detector = MissedTurnDetector()
        let firstScan = Date(timeIntervalSince1970: 100_000)
        let old = Conversation(sessionID: "tracked", application: app, title: "Task", cwd: "", updatedAt: firstScan.addingTimeInterval(-3600), state: .completed, evidence: "", revision: "turn-1|completed")
        #expect(detector.missedTurns(in: [old], scanStarted: firstScan).isEmpty, "the first scan is only a baseline")
        let secondScan = firstScan.addingTimeInterval(8)
        #expect(detector.missedTurns(in: [old], scanStarted: secondScan).isEmpty, "an unchanged turn is not new")
        let quick = Conversation(sessionID: "tracked", application: app, title: "Task", cwd: "", updatedAt: secondScan.addingTimeInterval(3), state: .completed, evidence: "", revision: "turn-2|completed")
        let fresh = Conversation(sessionID: "new", application: app, title: "New", cwd: "", updatedAt: secondScan.addingTimeInterval(5), state: .failed, evidence: "", revision: "turn-9|failed")
        let reappeared = Conversation(sessionID: "old-archive", application: app, title: "Old", cwd: "", updatedAt: firstScan.addingTimeInterval(-86400), state: .completed, evidence: "", revision: "turn-5|completed")
        let missed = detector.missedTurns(in: [quick, fresh, reappeared], scanStarted: secondScan.addingTimeInterval(8))
        #expect(Set(missed.map(\.sessionID)) == ["tracked", "new"])
    }

    @Test func recoveredExecutionRespectsAcceptance() {
        var ledger = TrackingLedger()
        let finished = execution("turn-1", .completed)
        ledger.recoverMissedExecution(finished)
        #expect(ledger.contains(finished))
        ledger.accept(finished)
        ledger.recoverMissedExecution(finished)
        #expect(!ledger.contains(finished))
    }
}
