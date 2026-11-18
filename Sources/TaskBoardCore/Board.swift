import Foundation

/// What GitHub and Jira currently say about the tasks, keyed by PR URL and Jira key.
public struct RemoteState: Equatable, Codable {
    public var pullRequests: [String: PullRequestInfo]
    public var jiraIssues: [String: JiraIssue]

    public init(pullRequests: [String: PullRequestInfo] = [:], jiraIssues: [String: JiraIssue] = [:]) {
        self.pullRequests = pullRequests
        self.jiraIssues = jiraIssues
    }

    public func pullRequest(for task: TaskItem) -> PullRequestInfo? {
        task.pr.flatMap { pullRequests[$0] }
    }

    public func jiraIssue(for task: TaskItem) -> JiraIssue? {
        task.jira.flatMap { jiraIssues[$0] }
    }
}

/// The status shown for a task, after folding in its pull request (and, for a parent, its subtasks).
public struct ResolvedStatus: Equatable {
    public var status: TaskStatus
    /// Human-readable reasons the task needs attention. Empty unless `status == .needsAttention`.
    public var reasons: [String]

    public init(status: TaskStatus, reasons: [String] = []) {
        self.status = status
        self.reasons = reasons
    }
}

/// A top-level task with its subtasks.
public struct TaskNode: Identifiable, Equatable {
    public var task: TaskItem
    public var subtasks: [TaskItem]
    public var id: String { task.id }

    public init(task: TaskItem, subtasks: [TaskItem] = []) {
        self.task = task
        self.subtasks = subtasks
    }

    /// Most recent change to the task or any of its subtasks.
    public var lastActivity: Date {
        ([task] + subtasks).compactMap { $0.updated ?? $0.created }.max() ?? .distantPast
    }
}

public struct BoardColumn: Identifiable, Equatable {
    public var column: ColumnConfig
    public var nodes: [TaskNode]
    public var id: String { column.id }
}

public struct BoardSummary: Equatable {
    public var working = 0
    public var needsAttention = 0
    public var total = 0

    public init() {}
}

public enum StatusResolver {
    /// The status of one task on its own, ignoring any subtasks.
    public static func own(_ task: TaskItem, remote: RemoteState) -> ResolvedStatus {
        let pullRequest = remote.pullRequest(for: task)

        if task.status == .done { return ResolvedStatus(status: .done) }
        // An agent that is busy is presumably dealing with whatever is red.
        if task.status == .working { return ResolvedStatus(status: .working) }
        if pullRequest?.state == .merged { return ResolvedStatus(status: .done) }

        var reasons: [String] = []
        if task.status == .needsAttention {
            reasons.append(task.attention ?? "Agent is waiting on you")
        }
        if let pullRequest, pullRequest.state == .open || pullRequest.state == .draft {
            if pullRequest.checks == .failing {
                let names = pullRequest.failingChecks.prefix(3).joined(separator: ", ")
                reasons.append(names.isEmpty ? "CI is failing" : "CI is failing: \(names)")
            }
            if pullRequest.reviewDecision == "CHANGES_REQUESTED" {
                reasons.append("Changes requested on the PR")
            }
        }
        return reasons.isEmpty
            ? ResolvedStatus(status: .idle)
            : ResolvedStatus(status: .needsAttention, reasons: reasons)
    }

    /// The summary status for a top-level task: its own status folded together with its subtasks.
    public static func rollup(_ node: TaskNode, remote: RemoteState) -> ResolvedStatus {
        let own = own(node.task, remote: remote)
        guard !node.subtasks.isEmpty else { return own }
        if own.status == .done { return own }

        let children = node.subtasks.map { (task: $0, resolved: Self.own($0, remote: remote)) }

        var reasons = own.reasons
        for child in children where child.resolved.status == .needsAttention {
            reasons.append(contentsOf: child.resolved.reasons.map { "\(child.task.title): \($0)" })
        }
        if !reasons.isEmpty { return ResolvedStatus(status: .needsAttention, reasons: reasons) }

        if own.status == .working || children.contains(where: { $0.resolved.status == .working }) {
            return ResolvedStatus(status: .working)
        }
        if children.allSatisfy({ $0.resolved.status == .done }) {
            return ResolvedStatus(status: .done)
        }
        return ResolvedStatus(status: .idle)
    }
}

public enum BoardBuilder {
    /// Groups tasks under their top-level parents. Deeper nesting is flattened to one level,
    /// and a subtask whose parent is missing is shown as a top-level task rather than hidden.
    public static func tree(tasks: [TaskItem]) -> [TaskNode] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var roots: [TaskItem] = []
        var children: [String: [TaskItem]] = [:]

        for task in tasks {
            if let root = TaskStore.rootParent(of: task.parent, byID: byID), root != task.id, byID[root] != nil {
                children[root, default: []].append(task)
            } else {
                roots.append(task)
            }
        }

        return roots.map { root in
            let subtasks = (children[root.id] ?? []).sorted { lhs, rhs in
                // Finished subtasks sink; otherwise newest first so fresh work shows at the top.
                let lhsDone = lhs.status == .done, rhsDone = rhs.status == .done
                if lhsDone != rhsDone { return !lhsDone }
                return (lhs.created ?? .distantPast) > (rhs.created ?? .distantPast)
            }
            return TaskNode(task: root, subtasks: subtasks)
        }
    }

    public static func columns(tasks: [TaskItem], config: BoardConfig, remote: RemoteState) -> [BoardColumn] {
        guard let firstColumn = config.columns.first else { return [] }
        var buckets: [String: [TaskNode]] = [:]
        for node in tree(tasks: tasks) {
            let column = placement(of: node, config: config, remote: remote) ?? firstColumn
            buckets[column.id, default: []].append(node)
        }
        return config.columns.map { column in
            let nodes = (buckets[column.id] ?? []).sorted { $0.lastActivity > $1.lastActivity }
            return BoardColumn(column: column, nodes: nodes)
        }
    }

    /// An explicit `column` always wins. Without one, the task moves on its own as its agent,
    /// pull request and status change.
    static func placement(of node: TaskNode, config: BoardConfig, remote: RemoteState) -> ColumnConfig? {
        if let explicit = node.task.column {
            return config.column(id: explicit)
        }
        let automation = config.automation
        let everything = [node.task] + node.subtasks

        if StatusResolver.rollup(node, remote: remote).status == .done {
            return config.column(id: automation.done)
        }

        func hasOpenPullRequest(_ task: TaskItem) -> Bool {
            guard task.pr != nil else { return false }
            guard let info = remote.pullRequest(for: task) else { return true }
            return info.state == .open || info.state == .draft
        }
        let unfinishedSubtasks = node.subtasks.filter { StatusResolver.own($0, remote: remote).status != .done }
        let inReview = hasOpenPullRequest(node.task)
            || (node.task.pr == nil && !unfinishedSubtasks.isEmpty && unfinishedSubtasks.allSatisfy(hasOpenPullRequest))
        if inReview, let column = config.column(id: automation.review) {
            return column
        }

        let isActive = everything.contains { $0.agent != nil || $0.pr != nil || $0.status != .idle }
        if isActive, let column = config.column(id: automation.active) {
            return column
        }
        return nil
    }

    public static func summary(columns: [BoardColumn], remote: RemoteState) -> BoardSummary {
        var summary = BoardSummary()
        for node in columns.flatMap(\.nodes) {
            for task in [node.task] + node.subtasks {
                summary.total += 1
                switch StatusResolver.own(task, remote: remote).status {
                case .working: summary.working += 1
                case .needsAttention: summary.needsAttention += 1
                case .idle, .done: break
                }
            }
        }
        return summary
    }
}
