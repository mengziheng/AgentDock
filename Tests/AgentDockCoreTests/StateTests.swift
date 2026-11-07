import Foundation
import Testing
@testable import AgentDockCore

@Suite struct StateTests {
    let now = Date(timeIntervalSince1970: 100_000)

    @Test func unfinishedTurnIsLiveOnlyWhileItsAppRuns() {
        let launched = now.addingTimeInterval(-3600)
        #expect(ExecutionState.liveness(raw: "inProgress", lastActivity: now.addingTimeInterval(-7200 + 3600), processLaunch: launched) == .running)
        // Hours of silence during a long tool call stay running.
        #expect(ExecutionState.liveness(raw: "inProgress", lastActivity: launched.addingTimeInterval(1), processLaunch: launched) == .running)
        #expect(ExecutionState.liveness(raw: "inProgress", lastActivity: now, processLaunch: nil) == .interrupted)
        // An app restarted after the turn's last activity abandoned that turn.
        #expect(ExecutionState.liveness(raw: "inProgress", lastActivity: now, processLaunch: now.addingTimeInterval(10)) == .interrupted)
        #expect(ExecutionState.liveness(raw: "awaitingInput", lastActivity: now, processLaunch: launched) == .awaitingInput)
        #expect(ExecutionState.liveness(raw: "completed", lastActivity: now, processLaunch: nil) == .completed)
    }

    @Test func categoriesPartitionAllStates() {
        #expect(ExecutionState.running.followUpCategory == .executing)
        #expect(ExecutionState.awaitingInput.followUpCategory == .awaitingInput)
        #expect(ExecutionState.completed.followUpCategory == .awaitingAcceptance)
        #expect([ExecutionState.failed, .interrupted, .unknown].allSatisfy { $0.followUpCategory == .abnormal })
    }

    @Test func devinFinalReplyCompletesTurnEvenWhileLockIsHeld() {
        let final = DevinTurn(headRole: "assistant", headFinishReason: "stop")
        #expect(final.state(lockHeld: true) == .completed)
        #expect(final.state(lockHeld: false) == .completed)
    }

    @Test func devinUnfinishedTurnDependsOnLock() {
        let tools = DevinTurn(headRole: "assistant", headToolNames: ["exec"], headFinishReason: "tool_calls")
        #expect(tools.state(lockHeld: true) == .running)
        #expect(tools.state(lockHeld: false) == .interrupted)
        #expect(DevinTurn(headRole: "tool").state(lockHeld: true) == .running)
        #expect(DevinTurn(headRole: "assistant", headFinishReason: "max_tokens").state(lockHeld: true) == .running)
        #expect(DevinTurn(headRole: "assistant", headToolNames: ["ask_user_question"]).state(lockHeld: true) == .awaitingInput)
        #expect(DevinTurn().state(lockHeld: true) == .unknown)
    }

    @Test func projectCatalogResolution() {
        let catalog = ProjectCatalog(projects: ["p": .init(name: "Real", roots: ["/repo"]), "nested": .init(name: "Nested", roots: ["/repo/nested"])], assignments: ["assigned": "p"], projectless: ["loose"])
        #expect(catalog.resolve(sessionID: "x", projectID: "p", cwd: "").name == "Real")
        #expect(catalog.resolve(sessionID: "assigned", projectID: nil, cwd: "").name == "Real")
        #expect(catalog.resolve(sessionID: "loose", projectID: nil, cwd: "/repo").name != "Real")
        #expect(catalog.resolve(sessionID: "x", projectID: nil, cwd: "/repo/nested/src").name == "Nested")
        #expect(catalog.resolve(sessionID: "x", projectID: nil, cwd: "/repo-other").name != "Real")
    }

    @Test func orcaTitleDecorationsAreHidden() {
        let item = Conversation(sessionID: "s", application: .orca, title: "⠋ [ ! ] Action Required | Fix tests", cwd: "", updatedAt: now, state: .awaitingInput, evidence: "", revision: "r")
        #expect(item.displayTitle == "Fix tests")
    }
}
