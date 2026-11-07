import Foundation

public struct ProjectDescriptor: Sendable {
    public let name: String
    public let roots: [String]
    public init(name: String, roots: [String]) { self.name = name; self.roots = roots }
}
public struct ProjectResolution: Sendable {
    public let name: String
    public let evidence: String
}
public struct ProjectCatalog: Sendable {
    public var projects: [String: ProjectDescriptor]
    public var assignments: [String: String]
    public var projectless: Set<String>
    public init(projects: [String: ProjectDescriptor] = [:], assignments: [String: String] = [:], projectless: Set<String> = []) {
        self.projects = projects; self.assignments = assignments; self.projectless = projectless
    }
    public func resolve(sessionID: String, projectID: String?, cwd: String) -> ProjectResolution {
        if let projectID, let project = projects[projectID] {
            return .init(name: project.name, evidence: String(localized: "Project link in the conversation database"))
        }
        if projectless.contains(sessionID) { return .init(name: String(localized: "No project"), evidence: String(localized: "The app marked this conversation as having no project; the working directory is shown separately")) }
        if let assigned = assignments[sessionID], let project = projects[assigned] {
            return .init(name: project.name, evidence: String(localized: "Project assignment saved by the app"))
        }
        // Longest boundary-aware root wins; do not confuse /repo with /repo-other.
        let matches = projects.values.flatMap { project in
            project.roots.compactMap { root -> (String, String)? in
                let normalized = root == "/" ? root : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let path = root.hasPrefix("/") && normalized != "/" ? "/" + normalized : normalized
                guard !path.isEmpty, cwd == path || cwd.hasPrefix(path == "/" ? path : path + "/") else { return nil }
                return (path, project.name)
            }
        }.sorted { $0.0.count > $1.0.count }
        if let match = matches.first {
            let equallySpecific = Set(matches.filter { $0.0.count == match.0.count }.map { $0.1 })
            if equallySpecific.count == 1 { return .init(name: match.1, evidence: String(localized: "Matched the working directory to a saved project root; no direct link found")) }
        }
        return .init(name: String(localized: "Project not identified"), evidence: String(localized: "No reliable project mapping; a working directory is not necessarily a project"))
    }
}
