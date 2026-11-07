import SwiftUI
import AppKit
import AgentDockCore

private let accent = DockTheme.accent

@main
struct AgentDockApp: App {
    @StateObject private var monitor = AppMonitor()
    var body: some Scene {
        WindowGroup("AgentDock") {
            DashboardView(monitor: monitor)
                .frame(minWidth: 1000, minHeight: 700)
                .background(WindowConfiguration())
        }
        .defaultSize(width: 1240, height: 850)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Conversations") { monitor.refresh() }.keyboardShortcut("r", modifiers: .command)
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
    }
}

private enum DashboardFilter: String, CaseIterable, Identifiable {
    case recent, running, review, input, unknown, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: String(localized: "Following")
        case .running: FollowUpCategory.executing.title
        case .input: FollowUpCategory.awaitingInput.title
        case .review: FollowUpCategory.awaitingAcceptance.title
        case .unknown: FollowUpCategory.abnormal.title
        case .all: String(localized: "Library")
        }
    }
    var category: FollowUpCategory? {
        switch self {
        case .running: .executing
        case .input: .awaitingInput
        case .review: .awaitingAcceptance
        case .unknown: .abnormal
        case .recent, .all: nil
        }
    }
    var symbol: String {
        switch self {
        case .recent: "clock"
        case .running: "bolt.fill"
        case .input: "questionmark.bubble.fill"
        case .review: "tray.fill"
        case .unknown: "exclamationmark.triangle"
        case .all: "square.stack"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: AppMonitor
    @State private var filter: DashboardFilter = .recent
    @State private var appID: String?
    @State private var search = ""
    @State private var selectedID: String?
    @State private var showSources = false
    private var selected: Conversation? { filtered.first { $0.id == selectedID } }
    private func items(for filter: DashboardFilter) -> [Conversation] {
        filter == .all ? monitor.conversations : monitor.trackedConversations
    }
    private func matches(_ conversation: Conversation, filter: DashboardFilter) -> Bool {
        filter.category.map { conversation.state.followUpCategory == $0 } ?? true
    }
    private var filtered: [Conversation] {
        items(for: filter).filter {
            matches($0, filter: filter) && (appID == nil || $0.application.id == appID) &&
            (search.isEmpty || ($0.displayTitle + $0.projectName + $0.cwd + $0.sessionID).localizedCaseInsensitiveContains(search))
        }
    }
    /// Conversations in the current view that can be accepted together.
    private var acceptable: [Conversation] {
        guard filter == .review || filter == .unknown else { return [] }
        return filtered.filter { monitor.ledger.contains($0) }
    }
    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 222, idealWidth: 258, maxWidth: 380)
            HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                HStack(spacing: 14) {
                    metric(.running, color: accent)
                    metric(.review, color: DockTheme.success)
                    metric(.input, color: DockTheme.warning)
                    metric(.unknown, color: DockTheme.error)
                }.padding(.horizontal, 28).padding(.bottom, 24)
                HStack(spacing: 12) {
                    Text(filter.title).font(.system(size: 21, weight: .semibold))
                    Text(verbatim: "\(filtered.count)").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                    if !acceptable.isEmpty {
                        Button("Accept All") { monitor.acknowledge(acceptable) }
                            .buttonStyle(DockActionStyle()).hoverFeedback()
                            .help("Remove every conversation shown here from Following. Original conversations are not deleted.")
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search title, project, or ID", text: $search).textFieldStyle(.plain).font(.system(size: 15))
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).hoverFeedback() }
                    }.padding(11).frame(width: 280).background(DockTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                }.padding(.horizontal, 28).padding(.bottom, 16)
                if filtered.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: filter.symbol).font(.system(size: 44)).foregroundStyle(accent.opacity(0.65))
                        Text("No conversations match this filter").font(.system(size: 22, weight: .semibold))
                        Text("Only connected sources are counted. An unconnected source or an unclear status does not mean the task has ended.")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filtered) { conversation in
                                ConversationCard(conversation: conversation, needsReview: monitor.ledger.contains(conversation), selected: selectedID == conversation.id, monitor: monitor)
                                    .onTapGesture { selectedID = conversation.id }
                            }
                        }.padding(.horizontal, 28).padding(.bottom, 24)
                    }
                }
                if let batch = monitor.undoBatch {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(DockTheme.success)
                        Text("\(batch.entries.count) accepted")
                        Spacer()
                        Button("Undo") { monitor.undoAcknowledge() }.buttonStyle(DockActionStyle()).hoverFeedback()
                    }.font(.system(size: 14)).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(DockTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DockTheme.border))
                        .padding(.horizontal, 28).padding(.bottom, 12)
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(monitor.isRefreshing ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text("Local and read-only · refreshes every 8 seconds · \(monitor.lastRefresh.formatted(date: .omitted, time: .standard))")
                    Spacer()
                    Button("Source Details") { showSources = true }.buttonStyle(.plain).hoverFeedback().foregroundStyle(accent)
                }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 13)
            }.background(DockTheme.canvas)
            if let selected {
                Divider()
                details(selected).frame(width: 290)
            }
            }.frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(accent)
        .sheet(isPresented: $showSources) { sourceSheet }
        .alert("Open Conversation", isPresented: Binding(get: { monitor.notice != nil }, set: { if !$0 { monitor.notice = nil } })) {
            Button("OK") { monitor.notice = nil }
        } message: { Text(monitor.notice ?? "") }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Every conversation, accounted for.") .font(.system(size: 30, weight: .bold))
                Text("See what is still working, what just finished, and what needs you.") .font(.system(size: 16)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 17)).padding(9)
            }.buttonStyle(DockActionStyle()).hoverFeedback().help("Enter or exit full screen ⌃⌘F")
            Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 17)).padding(9) }
                .buttonStyle(DockActionStyle()).hoverFeedback().disabled(monitor.isRefreshing).help("Refresh conversations ⌘R")
        }.padding(28)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 26)).foregroundStyle(accent)
                Text(verbatim: "AgentDock").font(.system(size: 23, weight: .bold))
            }.padding(.top, 30).padding(.bottom, 34)
            Text("Workspace").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 12)
            ForEach(DashboardFilter.allCases) { item in
                Button { filter = item } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.symbol).frame(width: 20)
                        Text(item.title)
                        Spacer()
                        Text(verbatim: "\(items(for: item).filter { matches($0, filter: item) && (appID == nil || $0.application.id == appID) }.count)").font(.system(size: 13, weight: .medium))
                    }.font(.system(size: 15, weight: filter == item ? .semibold : .regular))
                        .foregroundStyle(filter == item ? accent : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .background(filter == item ? DockTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).hoverFeedback().padding(.bottom, 3)
            }
            Text("Sources").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 28).padding(.bottom, 10)
            sourceButton(id: nil, title: String(localized: "All apps"), connected: nil)
            ForEach(monitor.sources) { source in
                sourceButton(id: source.id, title: source.application.name, connected: source.connected)
            }
            Spacer(minLength: 24)
            Text("Counts individual conversations,\nnot running apps.")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
                .padding(.horizontal, 10).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 18).padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DockTheme.sidebar)
    }
    private func sourceButton(id: String?, title: String, connected: Bool?) -> some View {
        Button { appID = id } label: {
            HStack(spacing: 10) {
                Text(title)
                Spacer()
                if let connected { Circle().fill(connected ? Color.green : Color.orange).frame(width: 6, height: 6) }
            }.foregroundStyle(appID == id ? accent : Color.primary).font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(appID == id ? DockTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).hoverFeedback()
    }
    private func metric(_ target: DashboardFilter, color: Color) -> some View {
        Button { filter = target } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(target.title).font(.system(size: 15, weight: .medium)); Spacer(); Image(systemName: target.symbol).foregroundStyle(color) }
                Text(verbatim: "\(target.category.map(monitor.count) ?? 0)").font(.system(size: 36, weight: .semibold, design: .rounded)).foregroundStyle(color)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(DockTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(DockTheme.border))
        }.buttonStyle(.plain).hoverFeedback()
    }
    private func details(_ item: Conversation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Text("Conversation Details").font(.system(size: 19, weight: .semibold)); Spacer(); Button { selectedID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).hoverFeedback() }
                Text(item.displayTitle).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
                StatusBadge(state: item.state)
                detailField("Status evidence", item.evidence)
                detailField("Source", item.application.name)
                detailField("Project", item.projectName)
                detailField("How the project was identified", item.projectEvidence)
                detailField("Working directory", item.cwd)
                detailField("Title source", item.titleEvidence)
                if !item.openingMessage.isEmpty {
                    DisclosureGroup("Opening message") {
                        Text(item.openingMessage).font(.system(size: 14)).textSelection(.enabled)
                    }
                }
                detailField("Conversation ID", item.sessionID)
                Button("Copy Conversation ID") { monitor.copy(item.sessionID) }.buttonStyle(DockActionStyle()).hoverFeedback()
                if let started = item.startedAt {
                    detailField("Turn started", started.formatted(date: .abbreviated, time: .standard))
                }
                detailField("Last activity", item.updatedAt.formatted(date: .abbreviated, time: .standard))
                Divider()
                Text("“Turn complete” only means this turn ended; the overall task may still need follow-up. An unfinished turn counts as running only while its app is running.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                Button("Open This Conversation") { monitor.activate(item) }.buttonStyle(.borderedProminent).hoverFeedback()
                    .help("Jumps to this conversation when the source supports it; otherwise opens the app and copies the title")
            }.padding(22)
        }.background(DockTheme.surface.opacity(0.5))
    }
    private func detailField(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(value.isEmpty ? String(localized: "Not provided") : value).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var sourceSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sources and Counting Rules").font(.system(size: 25, weight: .bold))
            ForEach(monitor.sources) { source in
                HStack(spacing: 14) {
                    Image(systemName: source.application.iconName).font(.system(size: 22)).frame(width: 32).foregroundStyle(source.connected ? accent : .orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.application.name).font(.system(size: 17, weight: .semibold))
                        Text(source.detail).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
            }
            if let issue = monitor.configurationIssue {
                Text(issue).font(.system(size: 14)).foregroundStyle(DockTheme.error)
            }
            Divider()
            Text("Conversations detected as running or waiting for input join Following. They stay after finishing, failing, or being interrupted until you click Accept, and come back when a new turn starts. Accepting only removes AgentDock's record; the original conversation is untouched.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            Text("Only conversations recognizable in local storage are listed; this is not the set of tabs currently open. To add another Codex-compatible app, list it in ~/Library/Application Support/AgentDock/codex-apps.json.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { showSources = false }.buttonStyle(.borderedProminent).hoverFeedback() }
        }.padding(30).frame(width: 620)
    }
}

private struct StatusBadge: View {
    let state: ExecutionState
    private var color: Color {
        switch state {
        case .running: accent
        case .awaitingInput: DockTheme.warning
        case .completed: DockTheme.success
        case .failed: DockTheme.error
        case .interrupted: DockTheme.warning
        case .unknown: .secondary
        }
    }
    var body: some View {
        Label(state.title, systemImage: state.symbol).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.10), in: Capsule())
    }
}

private struct ConversationCard: View {
    let conversation: Conversation
    let needsReview: Bool
    let selected: Bool
    @ObservedObject var monitor: AppMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Text(conversation.displayTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(conversation.displayTitle)
                StatusBadge(state: conversation.state)
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(conversation.application.name).fixedSize()
                Text(verbatim: "/").foregroundStyle(.tertiary)
                Text(conversation.projectName)
                    .lineLimit(2)
                    .help(conversation.projectEvidence)
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                cardTime
                Spacer()
                if needsReview && conversation.state != .awaitingInput {
                    Button("Accept") { monitor.acknowledge([conversation]) }
                        .buttonStyle(DockActionStyle()).hoverFeedback()
                        .help("Accept and remove from Following. The original conversation is not deleted and running work is not stopped.")
                        .accessibilityHint("Removes it from Following without deleting the original conversation")
                }
                Button { monitor.activate(conversation) } label: {
                    Label(conversation.state == .awaitingInput ? LocalizedStringKey("Answer") : LocalizedStringKey("Open"), systemImage: "arrow.up.right")
                }
                    .buttonStyle(DockActionStyle()).hoverFeedback()
                    .help("Jumps to this conversation when the source supports it; otherwise explains what happened")
            }.font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(20)
            .background(DockTheme.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(selected ? accent.opacity(0.65) : DockTheme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
    }
    @ViewBuilder private var cardTime: some View {
        if conversation.state == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(conversation.startedAt ?? conversation.updatedAt)))
                Text("Running for \(duration(seconds))")
                    .monospacedDigit()
                    .help(conversation.startedAt == nil ? LocalizedStringKey("Measured from the latest recorded activity; the source did not record when this turn started") : LocalizedStringKey("Measured from the start of this turn"))
            }
        } else {
            Text(eventTimeLabel)
                .help(conversation.updatedAt.formatted(date: .complete, time: .standard))
        }
    }
    private var eventTimeLabel: String {
        let time = conversation.updatedAt.formatted(date: .omitted, time: .shortened)
        switch conversation.state {
        case .awaitingInput: return String(localized: "Waiting since \(time)")
        case .completed: return String(localized: "Completed at \(time)")
        case .failed: return String(localized: "Failed at \(time)")
        case .interrupted: return String(localized: "Interrupted at \(time)")
        case .unknown: return String(localized: "Last activity \(time)")
        case .running: return ""
        }
    }
    private func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remaining = seconds % 60
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m") }
        if minutes > 0 { return String(localized: "\(minutes)m \(remaining)s") }
        return String(localized: "\(remaining)s")
    }
}
