import Foundation

public struct TrackedApplication: Identifiable, Hashable, Codable, Sendable {
    public let bundleID: String
    public let name: String
    public let iconName: String

    public var id: String { bundleID }

    public init(bundleID: String, name: String, iconName: String) { self.bundleID = bundleID; self.name = name; self.iconName = iconName }

    public static let orca = TrackedApplication(bundleID: "com.stablyai.orca", name: "Orca", iconName: "wave.3.right")
    public static let devin = TrackedApplication(bundleID: "com.exafunction.windsurf", name: "Devin", iconName: "person.crop.circle.badge.gearshape")
}

/// A desktop app that stores Codex-compatible threads (`state_5.sqlite`, `thread_history_1.sqlite`, rollout logs).
public struct CodexAppSource: Codable, Hashable, Sendable {
    public let name: String
    public let bundleID: String
    /// Directory containing `state_5.sqlite`; a leading `~` means the user's home directory.
    public let dataDirectory: String
    /// App that receives `codex://threads/<id>` for these threads. Defaults to `bundleID`.
    public let threadHandlerBundleID: String?
    /// Process that executes turns. Defaults to the thread handler.
    public let processBundleID: String?
    /// Location used when LaunchServices cannot resolve the thread handler.
    public let applicationPath: String?

    public init(name: String, bundleID: String, dataDirectory: String, threadHandlerBundleID: String? = nil, processBundleID: String? = nil, applicationPath: String? = nil) {
        self.name = name; self.bundleID = bundleID; self.dataDirectory = dataDirectory
        self.threadHandlerBundleID = threadHandlerBundleID; self.processBundleID = processBundleID; self.applicationPath = applicationPath
    }

    public var application: TrackedApplication { .init(bundleID: bundleID, name: name, iconName: "terminal.fill") }
    public var handlerBundleID: String { threadHandlerBundleID ?? bundleID }
    public var executorBundleID: String { processBundleID ?? handlerBundleID }
    public func dataRoot(home: String) -> String {
        dataDirectory.hasPrefix("~") ? home + dataDirectory.dropFirst() : dataDirectory
    }

    public static let officialCodex = CodexAppSource(name: String(localized: "Official Codex"), bundleID: "com.openai.codex", dataDirectory: "~/.codex", applicationPath: "/Applications/ChatGPT.app")

    public static func configurationPath(home: String) -> String {
        home + "/Library/Application Support/AgentDock/codex-apps.json"
    }

    /// Official Codex plus the user's locally configured Codex-compatible apps.
    public static func load(home: String) -> (apps: [CodexAppSource], issue: String?) {
        let path = configurationPath(home: home)
        guard let data = FileManager.default.contents(atPath: path) else { return ([officialCodex], nil) }
        do {
            let configured = try JSONDecoder().decode([CodexAppSource].self, from: data)
            return ([officialCodex] + configured.filter { $0.bundleID != officialCodex.bundleID }, nil)
        } catch {
            return ([officialCodex], String(localized: "Could not read \(path): \(error.localizedDescription)"))
        }
    }
}
