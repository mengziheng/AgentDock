import Foundation

/// Mutually exclusive workbench categories; detailed execution states remain on cards.
public enum FollowUpCategory: String, CaseIterable, Sendable {
    case executing, awaitingInput, awaitingAcceptance, abnormal
    public var title: String {
        switch self {
        case .executing: String(localized: "Running")
        case .awaitingInput: String(localized: "Needs input")
        case .awaitingAcceptance: String(localized: "To review")
        case .abnormal: String(localized: "Issues")
        }
    }
}

extension ExecutionState {
    public var followUpCategory: FollowUpCategory {
        switch self {
        case .running: .executing
        case .awaitingInput: .awaitingInput
        case .completed: .awaitingAcceptance
        case .failed, .interrupted, .unknown: .abnormal
        }
    }
}
