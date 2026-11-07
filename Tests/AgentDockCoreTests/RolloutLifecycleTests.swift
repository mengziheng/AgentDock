import Foundation
import Testing
@testable import AgentDockCore

@Suite struct RolloutLifecycleTests {
    func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    func event(_ type: String, _ stamp: String, _ turn: String, error: Any? = nil) -> Data {
        var payload: [String: Any] = ["type": type, "turn_id": turn]
        if let error { payload["error"] = error }
        return line(["type": "event_msg", "timestamp": stamp, "payload": payload])
    }
    func appended(_ stamp: String, _ turn: String, _ item: [String: Any]) -> Data {
        line(["type": "history_mutation", "timestamp": stamp, "payload": ["operation": "append", "turn_id": turn, "items": [item]]])
    }

    @Test func turnEvents() {
        let start = event("task_started", "2026-10-30T15:26:59.709Z", "t1")
        let end = event("task_complete", "2026-10-30T15:28:09.719Z", "t1")
        #expect(RolloutLifecycle.parse([Data("broken".utf8), start])?.status == "inProgress")
        let finished = RolloutLifecycle.parse([start, end])
        #expect(finished?.status == "completed" && finished?.turnID == "t1")
        #expect(finished?.startedAt != nil)
        let failedEnd = event("task_complete", "2026-10-30T15:55:39.999Z", "t1", error: ["message": "unexpected status 409 Conflict"])
        let failed = RolloutLifecycle.parse([start, failedEnd])
        #expect(failed?.status == "failed" && failed?.errorSummary?.contains("409") == true)
        #expect(RolloutLifecycle.errorSummary(NSNull()) == nil)
        #expect(RolloutLifecycle.parse([failedEnd, event("task_started", "2026-10-30T16:00:00.000Z", "t2")])?.status == "inProgress")
    }

    @Test func pendingUserQuestionMeansAwaitingInput() {
        let start = event("task_started", "2026-11-06T10:00:00.000Z", "t1")
        let ask = appended("2026-11-06T10:01:00.000Z", "t1", ["type": "function_call", "call_id": "c1", "name": "request_user_input", "arguments": #"{"questions":[{"question":"Which one?"}]}"#])
        #expect(RolloutLifecycle.parse([start, ask])?.status == "awaitingInput")
        let answer = appended("2026-11-06T10:02:00.000Z", "t1", ["type": "function_call_output", "call_id": "c1", "output": "A"])
        #expect(RolloutLifecycle.parse([start, ask, answer])?.status == "inProgress")
        let end = event("task_complete", "2026-11-06T10:03:00.000Z", "t1")
        #expect(RolloutLifecycle.parse([start, ask, end])?.status == "completed")
        let nonBlocking = appended("2026-11-06T10:01:00.000Z", "t1", ["type": "function_call", "call_id": "c2", "name": "AskUserQuestion", "arguments": #"{"isBlocking":false,"questions":[{"question":"FYI"}]}"#])
        #expect(RolloutLifecycle.parse([start, nonBlocking])?.status == "inProgress")
    }
}
