import Foundation

/// A change that cannot be made, with a message fit to show whoever asked for it.
public struct TaskEditError: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// The one place that knows how a task's fields may be changed. The command line tool and the
/// HTTP API both go through it, so they accept and refuse exactly the same things.
public enum TaskEdit {
    /// Fields in the order they are applied. `status` comes before `reason`, because setting a
    /// status clears the old reason.
    public static let fields = [
        "title", "parent", "column", "status", "reason", "jira", "pr", "workspace", "branch", "body", "note",
    ]

    public static func validatedTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TaskEditError("A title cannot be empty.") }
        guard title.count <= TaskItem.maxTitleLength else {
            throw TaskEditError("Titles are at most \(TaskItem.maxTitleLength) characters; this one is \(title.count). Shorten it.")
        }
        return title
    }

    public static func status(_ raw: String) throws -> TaskStatus {
        guard let status = TaskStatus(lenient: raw) else {
            throw TaskEditError("Unknown status '\(raw)'. Use idle, working, needs-attention or done.")
        }
        return status
    }

    /// Applies named changes to a task. A `nil` value clears the field.
    ///
    /// - `column`: a column's name or id; `nil` or `auto` lets the task place itself.
    /// - `reason`: why the task needs attention.
    /// - `note`: appended to the body as a new paragraph, where `body` replaces it.
    public static func apply(
        _ changes: [String: String?],
        to task: inout TaskItem,
        config: BoardConfig,
        store: TaskStore
    ) throws {
        if let unknown = changes.keys.sorted().first(where: { !fields.contains($0) }) {
            throw TaskEditError("Unknown field '\(unknown)'. Fields: \(fields.joined(separator: ", ")).")
        }

        for field in fields {
            guard let change = changes[field] else { continue }
            switch field {
            case "title":
                guard let change else { throw TaskEditError("A task needs a title.") }
                task.title = try validatedTitle(change)
            case "parent":
                if let change {
                    guard change != task.id else { throw TaskEditError("A task cannot be its own parent.") }
                    guard store.task(id: change) != nil else {
                        throw TaskEditError("No task with id '\(change)' to use as the parent.")
                    }
                    task.parent = change
                } else {
                    task.parent = nil
                }
            case "column":
                if let change, change.lowercased() != "auto" {
                    guard let column = config.column(id: change) else {
                        let names = config.columns.map(\.name).joined(separator: ", ")
                        throw TaskEditError("No column named '\(change)'. Columns: \(names).")
                    }
                    task.column = column.id
                } else {
                    task.column = nil
                }
            case "status":
                guard let change else { throw TaskEditError("A task needs a status.") }
                task.status = try status(change)
                task.awaitingApproval = false
                if task.status != .needsAttention { task.attention = nil }
            case "reason":
                task.attention = change
            case "jira":
                task.jira = change?.uppercased()
            case "pr":
                task.pr = change
            case "workspace":
                task.workspace = change.map { ($0 as NSString).expandingTildeInPath }
            case "branch":
                task.branch = change
            case "body":
                task.body = change ?? ""
            case "note":
                if let change, !change.isEmpty {
                    task.body = task.body.isEmpty ? change : task.body + "\n\n" + change
                }
            default:
                break
            }
        }
    }
}
