import Foundation

public enum TaskStoreError: Error, CustomStringConvertible {
    case notFound(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .notFound(let id): return "No task with id '\(id)'."
        case .invalid(let message): return message
        }
    }
}

/// Reads and writes the folder of task markdown files. One file per task or subtask.
public struct TaskStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(config: BoardConfig = .load()) {
        self.directory = BoardPaths.tasksDirectory(for: config)
    }

    // MARK: - Reading

    public func loadAll() -> [TaskItem] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var tasks: [TaskItem] = []
        var seen = Set<String>()
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.path < $1.path }
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let task = TaskItem(markdown: text, fallbackID: url.deletingPathExtension().lastPathComponent, fileURL: url)
            // Two files claiming one id: the first path wins, so the board never shows duplicates.
            if seen.insert(task.id).inserted {
                tasks.append(task)
            }
        }
        return tasks
    }

    public func task(id: String) -> TaskItem? {
        loadAll().first { $0.id == id }
    }

    public func require(id: String) throws -> TaskItem {
        guard let task = task(id: id) else { throw TaskStoreError.notFound(id) }
        return task
    }

    // MARK: - Writing

    /// Writes the task to its file, stamping `updated`. New tasks get a file named after their id.
    @discardableResult
    public func save(_ task: TaskItem, now: Date = Date()) throws -> TaskItem {
        var task = task
        if task.created == nil { task.created = now }
        task.updated = now
        let url = task.fileURL ?? directory.appendingPathComponent(task.id + ".md")
        task.fileURL = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try task.markdown().write(to: url, atomically: true, encoding: .utf8)
        return task
    }

    /// Creates a task with an id derived from its title, unique within the folder.
    @discardableResult
    public func create(_ draft: TaskItem, now: Date = Date()) throws -> TaskItem {
        var task = draft
        let existing = loadAll()
        task.id = Self.uniqueID(for: draft.id.isEmpty ? draft.title : draft.id, taken: Set(existing.map(\.id)))
        task.parent = Self.rootParent(of: task.parent, in: existing)
        task.fileURL = nil
        return try save(task, now: now)
    }

    public func delete(id: String) throws {
        let task = try require(id: id)
        if let url = task.fileURL {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    public static func uniqueID(for text: String, taken: Set<String>) -> String {
        let base = Slug.make(text).isEmpty ? "task" : Slug.make(text)
        if !taken.contains(base) { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// Subtasks are one level deep: a parent that is itself a subtask resolves to its top-level task.
    /// Returns `nil` for no parent, and for a parent chain that loops back on itself.
    public static func rootParent(of parent: String?, in tasks: [TaskItem]) -> String? {
        rootParent(of: parent, byID: Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    static func rootParent(of parent: String?, byID: [String: TaskItem]) -> String? {
        guard let parent, !parent.isEmpty else { return nil }
        var current = parent
        var visited: Set<String> = [current]
        // Climb only through parents that exist, so a dangling link higher up changes nothing here.
        while let next = byID[current]?.parent, !next.isEmpty, byID[next] != nil {
            guard visited.insert(next).inserted else { return nil }
            current = next
        }
        return current
    }
}
