import Foundation

public struct RolloutLifecycle: Sendable {
    public let turnID: String
    public let status: String
    public let timestamp: Date
    public let startedAt: Date?
    public let errorSummary: String?

    public static func parse(_ lines: [Data]) -> Self? {
        var parser = RolloutParser()
        lines.forEach { parser.consume($0) }
        return parser.lifecycle
    }

    public static func errorSummary(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : String(text.prefix(800)) }
        if let object = value as? [String: Any] {
            guard !object.isEmpty else { return nil }
            if let message = object["message"] as? String, !message.isEmpty { return String(message.prefix(800)) }
            return String(localized: "The run returned an error")
        }
        return String(localized: "The run returned an error")
    }
}

/// Folds rollout log lines into the latest turn lifecycle; can resume as the log grows.
struct RolloutParser {
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var latest: (turn: String, status: String, date: Date, error: String?)?
    private var starts: [String: Date] = [:]
    private var pendingInputs: [String: String] = [:]

    var lifecycle: RolloutLifecycle? {
        latest.map { .init(turnID: $0.turn, status: $0.status, timestamp: $0.date, startedAt: starts[$0.turn], errorSummary: $0.error) }
    }

    mutating func consume(_ line: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = event["payload"] as? [String: Any],
              let stamp = event["timestamp"] as? String,
              let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { return }
        if event["type"] as? String == "response_item" {
            consumeItem(payload, turnID: nil, date: date)
            return
        }
        if event["type"] as? String == "history_mutation" {
            if payload["operation"] as? String == "append", let items = payload["items"] as? [[String: Any]] {
                for item in items {
                    consumeItem(item, turnID: payload["turn_id"] as? String, date: date)
                }
            }
            return
        }
        guard event["type"] as? String == "event_msg",
              let type = payload["type"] as? String,
              let turn = payload["turn_id"] as? String else { return }
        let error = RolloutLifecycle.errorSummary(payload["error"])
        let status: String
        switch type {
        case "task_started": status = "inProgress"; starts[turn] = date
        case "task_complete": status = error == nil ? "completed" : "failed"
        case "turn_aborted": status = "interrupted"
        case "task_failed": status = "failed"
        case "error":
            guard error != nil || payload["message"] is String else { return }
            status = "failed"
        default: return
        }
        if starts[turn] == nil, let started = payload["started_at"] as? Double {
            starts[turn] = Date(timeIntervalSince1970: started)
        }
        if latest == nil || date >= latest!.date {
            pendingInputs = pendingInputs.filter { $0.value != turn }
            latest = (turn, status, date, error ?? (type == "error" ? payload["message"] as? String : nil))
        }
    }

    private mutating func consumeItem(_ item: [String: Any], turnID: String?, date: Date) {
        guard let kind = item["type"] as? String,
              let callID = item["call_id"] as? String else { return }
        if kind == "function_call_output" || kind == "custom_tool_call_output" {
            if let turn = pendingInputs.removeValue(forKey: callID),
               let previous = latest, previous.turn == turn, previous.status == "awaitingInput",
               !pendingInputs.values.contains(turn), date >= previous.date {
                latest = (turn, "inProgress", date, nil)
            }
            return
        }
        guard kind == "function_call" || kind == "custom_tool_call",
              let name = (item["name"] as? String)?.components(separatedBy: ".").last,
              name == "AskUserQuestion" || name == "request_user_input" else { return }
        let arguments: [String: Any]?
        if let text = item["arguments"] as? String, let data = text.data(using: .utf8) {
            arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else {
            arguments = item["arguments"] as? [String: Any]
        }
        guard let arguments, arguments["isBlocking"] as? Bool != false,
              let questions = arguments["questions"] as? [[String: Any]], !questions.isEmpty else { return }
        let metadata = item["internal_chat_message_metadata_passthrough"] as? [String: Any]
        guard let turn = metadata?["turn_id"] as? String ?? turnID ?? latest?.turn else { return }
        pendingInputs[callID] = turn
        if latest == nil || date >= latest!.date {
            latest = (turn, "awaitingInput", date, nil)
        }
    }
}

/// Parse position in one rollout log, so a growing log is only parsed from where the last scan stopped.
struct RolloutCursor {
    var offset: UInt64
    var parser: RolloutParser

    /// Resumes `cursor` when the file only grew; otherwise starts from a bounded tail.
    static func read(path: String, cursor: inout RolloutCursor?) -> RolloutLifecycle? {
        guard let handle = FileHandle(forReadingAtPath: path) else { cursor = nil; return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { cursor = nil; return nil }
        if var resumed = cursor, size >= resumed.offset {
            if size > resumed.offset, (try? handle.seek(toOffset: resumed.offset)) != nil, let data = try? handle.readToEnd() {
                resumed.offset += consumeCompleteLines(data, skipFirst: false, into: &resumed.parser)
            }
            cursor = resumed
            return resumed.parser.lifecycle
        }
        // Expand a bounded tail for long tool-heavy turns; never read an entire large rollout.
        var fresh = RolloutCursor(offset: size, parser: RolloutParser())
        for budget in [262_144, 1_048_576, 8_388_608] {
            let offset = size > UInt64(budget) ? size - UInt64(budget) : 0
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: Int(size - offset)) else { cursor = nil; return nil }
            fresh = RolloutCursor(offset: offset, parser: RolloutParser())
            fresh.offset += consumeCompleteLines(data, skipFirst: offset > 0, into: &fresh.parser)
            if fresh.parser.lifecycle != nil || offset == 0 { break }
        }
        cursor = fresh
        return fresh.parser.lifecycle
    }

    /// Consumes complete lines only and returns the number of bytes consumed; a partially
    /// written last line is left for the next read.
    private static func consumeCompleteLines(_ data: Data, skipFirst: Bool, into parser: inout RolloutParser) -> UInt64 {
        guard let lastNewline = data.lastIndex(of: 10) else { return 0 }
        var lines = data[data.startIndex..<lastNewline].split(separator: 10, omittingEmptySubsequences: false)
        if skipFirst && !lines.isEmpty { lines.removeFirst() }
        for line in lines where !line.isEmpty { parser.consume(Data(line)) }
        return UInt64(lastNewline - data.startIndex + 1)
    }
}
