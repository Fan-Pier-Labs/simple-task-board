import Foundation

/// What the agent on a task is doing right now.
public enum TaskStatus: String, CaseIterable, Codable, Sendable {
    /// Nobody is working on it.
    case idle
    /// An agent is actively working (shown as a spinner).
    case working
    /// The agent is waiting on you, or something like CI needs a look.
    case needsAttention = "needs-attention"
    case done

    /// Accepts the canonical names plus the synonyms people and agents tend to write.
    public init?(lenient raw: String) {
        let key = raw.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        switch key {
        case "idle", "todo", "to-do", "backlog", "open", "pending", "new":
            self = .idle
        case "working", "running", "in-progress", "active", "busy":
            self = .working
        case "needs-attention", "attention", "waiting", "blocked", "needs-input", "failed", "error":
            self = .needsAttention
        case "done", "complete", "completed", "finished", "merged", "closed":
            self = .done
        default:
            return nil
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsAttention: return "Needs attention"
        case .done: return "Done"
        }
    }
}

/// One task or subtask, backed by one markdown file.
public struct TaskItem: Identifiable, Equatable {
    /// Titles are meant to be scannable in a narrow card.
    public static let maxTitleLength = 50

    public var id: String
    public var title: String
    /// Column id. `nil` means "place me automatically" (see `BoardBuilder`).
    public var column: String?
    public var status: TaskStatus
    /// Id of the parent task. Subtasks are one level deep.
    public var parent: String?
    /// Jira issue key, e.g. `PROJ-123`. `nil` for a local-only task.
    public var jira: String?
    /// URL of the GitHub pull request.
    public var pr: String?
    /// Cursor chat id of the agent working on this task.
    public var cursorAgent: String?
    /// Folder the agent works in; used to discover the PR for its branch.
    public var workspace: String?
    public var branch: String?
    /// Why the task needs attention, when the agent said so.
    public var attention: String?
    /// True while the task is a stand-in made from an agent's first prompt, before the agent
    /// has filed itself under the right task.
    public var autoCreated: Bool
    public var created: Date?
    public var updated: Date?
    /// The markdown below the front matter.
    public var body: String
    public var fileURL: URL?

    /// Keys this app does not know about, kept so saving never drops them.
    var extraFields: [FrontMatterDocument.Field]

    public init(
        id: String,
        title: String,
        column: String? = nil,
        status: TaskStatus = .idle,
        parent: String? = nil,
        jira: String? = nil,
        pr: String? = nil,
        cursorAgent: String? = nil,
        workspace: String? = nil,
        branch: String? = nil,
        attention: String? = nil,
        autoCreated: Bool = false,
        created: Date? = nil,
        updated: Date? = nil,
        body: String = "",
        fileURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.column = column
        self.status = status
        self.parent = parent
        self.jira = jira
        self.pr = pr
        self.cursorAgent = cursorAgent
        self.workspace = workspace
        self.branch = branch
        self.attention = attention
        self.autoCreated = autoCreated
        self.created = created
        self.updated = updated
        self.body = body
        self.fileURL = fileURL
        self.extraFields = []
    }

    // MARK: - Markdown

    enum Key {
        static let id = "id"
        static let title = "title"
        static let column = "column"
        static let status = "status"
        static let parent = "parent"
        static let jira = "jira"
        static let pr = "pr"
        static let cursorAgent = "cursor_agent"
        static let workspace = "workspace"
        static let branch = "branch"
        static let attention = "attention"
        static let autoCreated = "auto_created"
        static let created = "created"
        static let updated = "updated"

        static let all: Set<String> = [
            id, title, column, status, parent, jira, pr, cursorAgent,
            workspace, branch, attention, autoCreated, created, updated,
        ]
    }

    /// Builds a task from the text of a markdown file. `fallbackID` is normally the file name.
    public init(markdown: String, fallbackID: String, fileURL: URL? = nil) {
        let document = FrontMatterDocument.parse(markdown)
        func value(_ key: String) -> String? {
            guard let raw = document[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw
        }

        self.id = value(Key.id) ?? fallbackID
        self.title = value(Key.title)
            ?? Self.firstHeading(in: document.body)
            ?? fallbackID.replacingOccurrences(of: "-", with: " ").capitalizedFirst
        self.column = value(Key.column)
        self.status = value(Key.status).flatMap(TaskStatus.init(lenient:)) ?? .idle
        self.parent = value(Key.parent)
        self.jira = value(Key.jira)?.uppercased()
        self.pr = value(Key.pr)
        self.cursorAgent = value(Key.cursorAgent)
        self.workspace = value(Key.workspace)
        self.branch = value(Key.branch)
        self.attention = value(Key.attention)
        self.autoCreated = value(Key.autoCreated)?.lowercased() == "true"
        self.created = value(Key.created).flatMap(DateCoding.parse)
        self.updated = value(Key.updated).flatMap(DateCoding.parse)
        self.body = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileURL = fileURL
        self.extraFields = document.fields.filter { !Key.all.contains($0.key) }
    }

    public func markdown() -> String {
        var document = FrontMatterDocument()
        document[Key.id] = id
        document[Key.title] = title
        document[Key.status] = status.rawValue
        document[Key.column] = column
        document[Key.parent] = parent
        document[Key.jira] = jira
        document[Key.pr] = pr
        document[Key.cursorAgent] = cursorAgent
        document[Key.workspace] = workspace
        document[Key.branch] = branch
        document[Key.attention] = attention
        document[Key.autoCreated] = autoCreated ? "true" : nil
        document[Key.created] = created.map(DateCoding.string)
        document[Key.updated] = updated.map(DateCoding.string)
        document.fields.append(contentsOf: extraFields)
        document.body = body
        return document.serialized()
    }

    private static func firstHeading(in body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? nil : heading
            }
        }
        return nil
    }

    // MARK: - Links

    /// Deep link that opens this task's agent chat in the Cursor desktop app.
    public var cursorURL: URL? {
        guard let cursorAgent, !cursorAgent.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "cursor"
        components.host = "anysphere.cursor-deeplink"
        components.path = "/agent"
        components.queryItems = [URLQueryItem(name: "id", value: cursorAgent)]
        return components.url
    }

    public var prURL: URL? {
        guard let pr, let url = URL(string: pr), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}

/// ISO 8601 timestamps, tolerant of date-only values typed by hand.
enum DateCoding {
    static func string(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func parse(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: raw)
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }

    /// Shortens to `limit` characters on a word boundary, ending in an ellipsis.
    public func truncatedTitle(limit: Int = TaskItem.maxTitleLength) -> String {
        let singleLine = components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard singleLine.count > limit else { return singleLine }
        let head = singleLine.prefix(limit - 1)
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return head[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return head + "…"
    }
}
