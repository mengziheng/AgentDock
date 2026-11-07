import AppKit
import AgentDockCore

// Reads the real local sources and prints counts only: no titles, paths, or message text.
let running = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in
    app.bundleIdentifier.map { ($0, app.launchDate ?? .distantPast) }
}, uniquingKeysWith: { min($0, $1) })
let scanner = ConversationScanner()
var scan: ScanResult?
for pass in ["cold", "warm"] {
    let start = Date()
    scan = scanner.scan(runningApplications: running)
    print("\(pass) scan: \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
}
guard let scan else { exit(1) }
if let issue = scan.configurationIssue { print("configuration: \(issue)") }
for source in scan.sources {
    let items = scan.conversations.filter { $0.application.id == source.id }
    let counts = ExecutionState.allCases.map { state in "\(state.rawValue)=\(items.filter { $0.state == state }.count)" }.joined(separator: " ")
    print("\(source.application.name): \(items.count) conversations · \(counts) · connected=\(source.connected)")
}
if Set(scan.conversations.map(\.id)).count != scan.conversations.count {
    print("error: duplicate conversations in scan")
    exit(1)
}
