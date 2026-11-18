import Foundation

/// Handles the JSON that Cursor sends to a hook command, keeping task files in step with
/// what each agent chat is doing.
///
/// - `sessionStart`: tells the new agent its chat id and how to file itself on the board.
/// - `beforeSubmitPrompt`: marks the chat's task as working, creating a stand-in task from the
///   prompt if the chat has none yet.
/// - `stop`: the agent finished a turn, so the task now waits on the user.
/// - `sessionEnd`: clears a spinner that would otherwise spin forever.
public struct CursorHooks {
    public static let events = ["sessionStart", "beforeSubmitPrompt", "stop", "sessionEnd"]

    public let store: TaskStore
    /// Path agents should use to call the CLI, as it will be written into their instructions.
    public let cliPath: String
    public var now: () -> Date = Date.init
    /// Looked up per workspace; injectable so tests do not shell out to git.
    public var branchLookup: (String) -> String? = Git.featureBranch(in:)

    public init(store: TaskStore, cliPath: String) {
        self.store = store
        self.cliPath = cliPath
    }

    /// Returns the JSON to print on stdout. Never throws: a hook must not get in the agent's way.
    public func handle(payload: Data) -> Data {
        let response = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])
            .flatMap { $0 }
            .map(respond(to:)) ?? [:]
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    func respond(to input: [String: Any]) -> [String: Any] {
        guard let event = input["hook_event_name"] as? String,
              let session = (input["conversation_id"] as? String) ?? (input["session_id"] as? String),
              !session.isEmpty
        else { return [:] }
        let workspace = (input["workspace_roots"] as? [String])?.first

        switch event {
        case "sessionStart":
            // "Ask" chats are questions, not work, so they stay off the board.
            if (input["composer_mode"] as? String) == "ask" {
                setIgnored(session, true)
                return [:]
            }
            return [
                "env": ["TASKBOARD_SESSION": session],
                "additional_context": Self.agentInstructions(session: session, cli: cliPath),
            ]

        case "beforeSubmitPrompt":
            if !isIgnored(session) {
                promptSubmitted(session: session, prompt: (input["prompt"] as? String) ?? "", workspace: workspace)
            }
            return ["continue": true]

        case "stop":
            turnEnded(session: session, status: (input["status"] as? String) ?? "completed", workspace: workspace)
            return [:]

        case "sessionEnd":
            if var task = task(for: session), task.status == .working {
                task.status = .idle
                _ = try? store.save(task, now: now())
            }
            setIgnored(session, false)
            return [:]

        default:
            return [:]
        }
    }

    // MARK: - Events

    private func promptSubmitted(session: String, prompt: String, workspace: String?) {
        if var task = task(for: session) {
            task.status = .working
            task.attention = nil
            recordWorkspace(workspace, on: &task)
            _ = try? store.save(task, now: now())
            return
        }

        // No task yet: show the chat on the board straight away. The agent re-files it
        // (see `SessionLinker`) once it has looked at the existing tasks.
        let title = prompt.truncatedTitle()
        var task = TaskItem(
            id: "",
            title: title.isEmpty ? "New Cursor agent" : title,
            status: .working,
            cursorAgent: session,
            autoCreated: true,
            body: prompt.isEmpty ? "" : "Started from this prompt:\n\n" + Self.quoted(prompt)
        )
        recordWorkspace(workspace, on: &task)
        _ = try? store.create(task, now: now())
    }

    private func turnEnded(session: String, status: String, workspace: String?) {
        guard var task = task(for: session) else { return }
        recordWorkspace(workspace, on: &task)
        // An agent that already marked itself done or blocked knows better than this hook.
        if task.status == .working {
            switch status {
            case "aborted":
                task.status = .idle
            case "error":
                task.status = .needsAttention
                task.attention = "Agent stopped with an error"
            default:
                task.status = .needsAttention
                task.attention = "Agent finished its turn"
            }
        }
        _ = try? store.save(task, now: now())
    }

    private func recordWorkspace(_ workspace: String?, on task: inout TaskItem) {
        guard let workspace, !workspace.isEmpty else { return }
        task.workspace = workspace
        if let branch = branchLookup(workspace) {
            task.branch = branch
        }
    }

    func task(for session: String) -> TaskItem? {
        store.loadAll().first { $0.cursorAgent == session }
    }

    // MARK: - Ignored chats

    private var sessionsDirectory: URL {
        store.directory.deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true)
    }

    private func marker(_ session: String) -> URL {
        sessionsDirectory.appendingPathComponent(Slug.make(session, maxLength: 80) + ".ignore")
    }

    private func isIgnored(_ session: String) -> Bool {
        FileManager.default.fileExists(atPath: marker(session).path)
    }

    private func setIgnored(_ session: String, _ ignored: Bool) {
        let url = marker(session)
        if ignored {
            try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Text

    static func quoted(_ prompt: String) -> String {
        let clipped = prompt.count > 2000 ? String(prompt.prefix(2000)) + "…" : prompt
        return clipped.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
    }

    /// The standing instructions handed to every new agent chat.
    public static func agentInstructions(session: String, cli: String) -> String {
        let tool = cli.contains(" ") ? "\"\(cli)\"" : cli
        return """
        This machine runs Task Board, a menu bar board that shows what every agent is working on. \
        Keep it accurate for this chat. This chat's session id is \(session).

        1. Before you start work, run `\(tool) list` to see the existing tasks and subtasks.
        2. Then file this chat where it belongs, with exactly one of:
           - `\(tool) attach <task-id> --session \(session)` when this chat continues an existing task or subtask.
           - `\(tool) add "<title>" --parent <task-id> --session \(session)` when this is a new piece of work under an existing top-level task.
           - `\(tool) add "<title>" --session \(session)` when it is unrelated to every existing task.
           A title says what is being done in at most \(TaskItem.maxTitleLength) characters.
        3. After you open a pull request, run `\(tool) update --pr <url> --session \(session)`. \
        If the work belongs to a Jira issue, add `--jira <KEY>`.
        4. When the task is completely finished, run `\(tool) status done --session \(session)`. \
        If you are blocked on the user, run `\(tool) status needs-attention --reason "<why>" --session \(session)`.

        Do this quietly: do not mention Task Board to the user unless one of these commands fails. \
        Skip all of it when the user only asks a question and there is no work to track.
        """
    }
}

/// How an agent files its chat under the right task, replacing the stand-in made from its prompt.
public struct SessionLinker {
    public let store: TaskStore
    public var now: () -> Date = Date.init

    public init(store: TaskStore) {
        self.store = store
    }

    private func standIn(for session: String, in tasks: [TaskItem]) -> TaskItem? {
        tasks.first { $0.cursorAgent == session && $0.autoCreated }
    }

    /// Points an existing task at this chat. The chat's stand-in task, if any, is removed.
    @discardableResult
    public func attach(taskID: String, session: String) throws -> TaskItem {
        let tasks = store.loadAll()
        guard var target = tasks.first(where: { $0.id == taskID }) else { throw TaskStoreError.notFound(taskID) }

        if let placeholder = standIn(for: session, in: tasks), placeholder.id != target.id {
            target.workspace = target.workspace ?? placeholder.workspace
            target.branch = placeholder.branch ?? target.branch
            try store.delete(id: placeholder.id)
        }
        // A chat works on one task at a time.
        for var other in tasks where other.cursorAgent == session && other.id != target.id && !other.autoCreated {
            other.cursorAgent = nil
            if other.status == .working { other.status = .idle }
            try store.save(other, now: now())
        }

        target.cursorAgent = session
        target.autoCreated = false
        target.status = .working
        target.attention = nil
        return try store.save(target, now: now())
    }

    /// Creates a task for this chat. If the chat already has a stand-in, that file is reused,
    /// so the card keeps its place instead of flickering.
    @discardableResult
    public func add(_ draft: TaskItem, session: String?) throws -> TaskItem {
        var draft = draft
        guard let session, !session.isEmpty else { return try store.create(draft, now: now()) }

        let tasks = store.loadAll()
        draft.cursorAgent = session
        if draft.status == .idle { draft.status = .working }

        guard var placeholder = standIn(for: session, in: tasks) else {
            for var other in tasks where other.cursorAgent == session {
                other.cursorAgent = nil
                if other.status == .working { other.status = .idle }
                try store.save(other, now: now())
            }
            return try store.create(draft, now: now())
        }

        placeholder.title = draft.title
        placeholder.parent = TaskStore.rootParent(of: draft.parent, in: tasks)
        placeholder.column = draft.column ?? placeholder.column
        placeholder.jira = draft.jira ?? placeholder.jira
        placeholder.pr = draft.pr ?? placeholder.pr
        placeholder.status = draft.status
        placeholder.autoCreated = false
        if !draft.body.isEmpty { placeholder.body = draft.body }

        // Rename the file to match the real title; it was named after the raw prompt.
        let oldURL = placeholder.fileURL
        let newID = TaskStore.uniqueID(for: draft.title, taken: Set(tasks.map(\.id)).subtracting([placeholder.id]))
        guard newID != placeholder.id else { return try store.save(placeholder, now: now()) }
        placeholder.id = newID
        placeholder.fileURL = nil
        let saved = try store.save(placeholder, now: now())
        if let oldURL { try? FileManager.default.removeItem(at: oldURL) }
        return saved
    }
}
