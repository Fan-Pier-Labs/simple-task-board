import AppKit
import SwiftUI
import TaskBoardCore

/// One top-level task: its row, and when opened, its details and its subtasks.
struct TaskCardView: View {
    let node: TaskNode
    @ObservedObject var model: BoardModel
    /// Two lines in the narrow board columns, one in the list.
    let titleLines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskRowView(
                task: node.task,
                resolved: model.resolvedStatus(for: node),
                subtaskCount: node.subtasks.count,
                isSubtask: false,
                titleLines: titleLines,
                model: model
            )
            if model.expandedDetails.contains(node.id) {
                TaskDetailView(task: node.task, resolved: model.resolvedStatus(for: node), model: model)
                    .padding(.leading, 40)
            }
            if model.expandedSubtasks.contains(node.id) {
                ForEach(node.subtasks) { subtask in
                    Divider().padding(.leading, 40)
                    TaskRowView(
                        task: subtask,
                        resolved: model.resolvedStatus(for: subtask),
                        subtaskCount: 0,
                        isSubtask: true,
                        titleLines: titleLines,
                        model: model
                    )
                    if model.expandedDetails.contains(subtask.id) {
                        TaskDetailView(task: subtask, resolved: model.resolvedStatus(for: subtask), model: model)
                            .padding(.leading, 40)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.09)))
    }
}

/// The collapsed line for a task: chevron and subtask count, status, title, and its links.
struct TaskRowView: View {
    let task: TaskItem
    let resolved: ResolvedStatus
    let subtaskCount: Int
    let isSubtask: Bool
    let titleLines: Int
    @ObservedObject var model: BoardModel

    private var subtasksOpen: Bool { model.expandedSubtasks.contains(task.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            disclosure
            StatusIconView(status: resolved.status)
                .frame(height: 20)
                .help(resolved.reasons.isEmpty ? resolved.status.label : resolved.reasons.joined(separator: "\n"))

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 13, weight: isSubtask ? .regular : .medium))
                    .foregroundStyle(resolved.status == .done ? .secondary : .primary)
                    .lineLimit(titleLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
                if let jira = task.jira {
                    JiraBadge(key: jira, issue: model.remote.jiraIssue(for: task), url: model.config.jiraURL(for: jira), open: model.open)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { toggle(\.expandedDetails) }
            .help("Show details")

            HStack(spacing: 0) {
                if let agent = task.agent, let url = task.agentURL {
                    HoverButton(help: "Open the agent in \(agent.kind.displayName)", action: { model.open(url) }) {
                        if let icon = Icons.appIcon(for: agent.kind) {
                            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 15, height: 15)
                        } else {
                            Image(systemName: agent.kind == .cursor ? "cursorarrow.rays" : "sparkle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                if let url = task.prURL {
                    PullRequestButton(url: url, info: model.remote.pullRequest(for: task), open: model.open)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, isSubtask ? 40 : 8)
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private var disclosure: some View {
        if subtaskCount > 0 {
            Button(action: { toggle(\.expandedSubtasks) }) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(subtasksOpen ? 90 : 0))
                    Text("\(subtaskCount)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 20, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(subtaskCount == 1 ? "1 subtask" : "\(subtaskCount) subtasks")
            .accessibilityLabel(subtasksOpen ? "Hide subtasks" : "Show \(subtaskCount) subtasks")
        } else if !isSubtask {
            // Keeps status icons in one line whether or not a task has subtasks.
            Color.clear.frame(width: 26, height: 20)
        }
    }

    private func toggle(_ set: ReferenceWritableKeyPath<BoardModel, Set<String>>) {
        withAnimation(.easeOut(duration: 0.12)) {
            if model[keyPath: set].contains(task.id) {
                model[keyPath: set].remove(task.id)
            } else {
                model[keyPath: set].insert(task.id)
            }
        }
    }
}

struct PullRequestButton: View {
    let url: URL
    let info: PullRequestInfo?
    let open: (URL) -> Void

    private var dotColor: Color? {
        guard let info else { return nil }
        switch info.state {
        case .merged: return .purple
        case .closed: return .gray
        case .open, .draft:
            switch info.checks {
            case .failing: return .red
            case .pending: return .yellow
            case .passing: return .green
            case .none: return nil
            }
        }
    }

    private var help: String {
        guard let info else { return "Open the pull request" }
        let number = info.number.map { "#\($0) " } ?? ""
        return "Pull request \(number)· \(info.summary)"
    }

    var body: some View {
        HoverButton(help: help, action: { open(url) }) {
            Image(nsImage: Icons.github)
                .renderingMode(.template)
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(.secondary)
                .overlay(alignment: .bottomTrailing) {
                    if let dotColor {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
                            .offset(x: 3, y: 2)
                    }
                }
        }
    }
}

struct JiraBadge: View {
    let key: String
    let issue: JiraIssue?
    let url: URL?
    let open: (URL) -> Void

    var body: some View {
        Button(action: { if let url { open(url) } }) {
            HStack(spacing: 4) {
                Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced))
                if let issue {
                    Text(issue.statusName).font(.system(size: 10))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(url == nil ? "Set the Jira site in Settings to open this issue" : "Open \(key) in Jira")
    }
}

/// The opened-up view of a task: why it needs attention, its links, and its markdown body.
struct TaskDetailView: View {
    let task: TaskItem
    let resolved: ResolvedStatus
    @ObservedObject var model: BoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(resolved.reasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if task.body.isEmpty {
                Text("No description.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                MarkdownView(text: task.body)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let info = model.remote.pullRequest(for: task) {
                    fact("Pull request", (info.number.map { "#\($0) · " } ?? "") + info.summary)
                }
                if let issue = model.remote.jiraIssue(for: task) {
                    fact("Jira", "\(issue.key) · \(issue.statusName)" + (issue.summary.isEmpty ? "" : " · \(issue.summary)"))
                } else if task.jira == nil {
                    fact("Jira", "Local only")
                }
                if let branch = task.branch { fact("Branch", branch) }
                if let workspace = task.workspace {
                    fact("Workspace", (workspace as NSString).abbreviatingWithTildeInPath)
                }
                if let updated = task.updated {
                    fact("Updated", updated.formatted(.relative(presentation: .named)))
                }
            }

            if let file = task.fileURL {
                HStack(spacing: 12) {
                    Button("Open file") { model.open(file) }
                    Button("Show in Finder") { model.revealInFinder(file) }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(.trailing, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).foregroundStyle(.tertiary).frame(width: 72, alignment: .leading)
            Text(value).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
        }
        .font(.system(size: 11))
    }
}
