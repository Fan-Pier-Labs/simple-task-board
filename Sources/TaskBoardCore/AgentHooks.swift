import Foundation

extension AgentKind {
    /// Which app the current process was started by, judging by the environment it was given.
    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentKind? {
        if environment["CLAUDECODE"] != nil || environment["CLAUDE_CODE_SESSION_ID"] != nil { return .claude }
        if environment.keys.contains(where: { $0.hasPrefix("CURSOR_") }) { return .cursor }
        return nil
    }
}

/// Small per-chat facts that are not worth a task file: that a chat is off the board, or that
/// it has already been reminded to file itself.
struct SessionMarks {
    enum Mark: String {
        /// The chat is not work, so no task is made for it.
        case ignore
        /// The chat has had its one reminder to file itself.
        case reminded
    }

    let directory: URL

    init(store: TaskStore) {
        directory = store.directory.deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true)
    }

    private func file(_ mark: Mark, _ session: String) -> URL {
        directory.appendingPathComponent(Slug.make(session, maxLength: 80) + "." + mark.rawValue)
    }

    func has(_ mark: Mark, _ session: String) -> Bool {
        FileManager.default.fileExists(atPath: file(mark, session).path)
    }

    func set(_ mark: Mark, _ session: String, _ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file(mark, session).path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: file(mark, session))
        }
    }
}

/// Handles the JSON that Cursor or Claude sends to a hook command, keeping task files in step
/// with what each agent chat is doing.
///
/// Both apps report the same few moments, under different names:
/// - a chat starts: tell the new agent its session id and how to file itself on the board;
/// - a prompt is submitted: the chat's task is working (a chat with no task yet gets a stand-in);
/// - the agent's turn ends, or it stops to ask for permission: the task now waits on the user;
/// - the chat closes: clear a spinner that would otherwise spin forever.
public struct AgentHooks {
    public let store: TaskStore
    /// Path agents should use to call the CLI, as it will be written into their instructions.
    public let cliPath: String
    public var now: () -> Date = Date.init
    /// Looked up per workspace; injectable so tests do not shell out to git.
    public var branchLookup: (String) -> String? = Git.featureBranch(in:)
    /// The hook process's environment. Claude's desktop app passes its own session id this way.
    public var environment: [String: String] = ProcessInfo.processInfo.environment

    public init(store: TaskStore, cliPath: String) {
        self.store = store
        self.cliPath = cliPath
    }

    /// What a hook call means, with the app-specific names stripped away.
    enum Signal: Equatable {
        case sessionStarted(questionsOnly: Bool)
        case promptSubmitted(String)
        /// `outcome` is `completed`, `aborted` or `error`. `canHold` is true when the app lets a hook
        /// send the agent back to finish something, and this is not already such a second pass.
        case turnEnded(outcome: String, canHold: Bool)
        /// `approval` is true when the agent is stopped on a permission prompt mid-turn.
        case waitingOnUser(reason: String, approval: Bool)
        /// A tool ran, so the agent is not stuck on a prompt any more.
        case moved
        case sessionEnded
    }

    struct Event: Equatable {
        var kind: AgentKind
        var session: String
        var workspace: String?
        var signal: Signal
    }

    /// Returns the bytes to print on stdout. Never throws: a hook must not get in the agent's way.
    public func handle(payload: Data, from kind: AgentKind) -> Data {
        var response: [String: Any] = [:]
        if let input = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
           let event = Self.parse(input, from: kind, environment: environment) {
            response = respond(to: event)
        }
        // Claude treats output as something to act on, so say nothing unless there is something to say.
        if response.isEmpty, kind == .claude { return Data() }
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// One line saying which chat a hook call belongs to, for the hook log.
    public func describe(payload: Data, from kind: AgentKind) -> String {
        guard let input = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let event = Self.parse(input, from: kind, environment: environment)
        else { return "not acted on" }
        return "session \(event.session) in \(event.workspace ?? "an unknown folder")"
    }

    // MARK: - Reading each app's payload

    static func parse(_ input: [String: Any], from kind: AgentKind, environment: [String: String]) -> Event? {
        guard let name = input["hook_event_name"] as? String else { return nil }
        func text(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        switch kind {
        case .cursor:
            guard let session = text("conversation_id") ?? text("session_id") else { return nil }
            let signal: Signal
            switch name {
            case "sessionStart": signal = .sessionStarted(questionsOnly: text("composer_mode") == "ask")
            case "beforeSubmitPrompt": signal = .promptSubmitted(text("prompt") ?? "")
            case "stop": signal = .turnEnded(outcome: text("status") ?? "completed", canHold: false)
            case "sessionEnd": signal = .sessionEnded
            default: return nil
            }
            let workspace = (input["workspace_roots"] as? [String])?.first
            return Event(kind: kind, session: session, workspace: workspace, signal: signal)

        case .claude:
            // In the desktop app, its own session id is what its deep links take, and it survives
            // the inner session being restarted. In a terminal there is only `session_id`.
            let desktopSession = environment["CLAUDE_CODE_HOST_SESSION_ID"].flatMap { $0.hasPrefix("local_") ? $0 : nil }
            guard let session = desktopSession ?? text("session_id") else { return nil }
            // Hooks also run inside subagents. Only their tool use says anything about the chat as a whole.
            let isSubagent = input["agent_id"] != nil
            let signal: Signal
            switch name {
            case "PostToolUse":
                signal = .moved
            case _ where isSubagent:
                return nil
            case "SessionStart":
                signal = .sessionStarted(questionsOnly: false)
            case "UserPromptSubmit":
                signal = .promptSubmitted(text("prompt") ?? "")
            case "Stop":
                signal = .turnEnded(outcome: "completed", canHold: (input["stop_hook_active"] as? Bool) != true)
            case "Notification":
                switch text("notification_type") {
                case "permission_prompt", "elicitation_dialog":
                    signal = .waitingOnUser(reason: text("message") ?? "Claude needs your permission", approval: true)
                case "idle_prompt":
                    // Also covers an interrupted turn, which sends no Stop.
                    signal = .waitingOnUser(reason: "Claude is waiting for your reply", approval: false)
                default:
                    return nil
                }
            case "SessionEnd":
                signal = .sessionEnded
            default:
                return nil
            }
            let workspace = environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? text("cwd")
            return Event(kind: kind, session: session, workspace: workspace, signal: signal)
        }
    }

    // MARK: - Acting on it

    func respond(to event: Event) -> [String: Any] {
        let session = event.session
        switch event.signal {
        case .sessionStarted(let questionsOnly):
            // Cursor's "Ask" chats are questions, not work, so they stay off the board.
            if questionsOnly {
                marks.set(.ignore, session, true)
                return [:]
            }
            let instructions = Self.agentInstructions(session: session, cli: cliPath)
            switch event.kind {
            case .cursor:
                return ["env": ["TASKBOARD_SESSION": session], "additional_context": instructions]
            case .claude:
                exportSessionToClaudeShell(session)
                return ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": instructions]]
            }

        case .promptSubmitted(let prompt):
            if !marks.has(.ignore, session) {
                promptSubmitted(event, prompt: prompt)
            }
            return event.kind == .cursor ? ["continue": true] : [:]

        case .turnEnded(let outcome, let canHold):
            guard var task = task(for: session) else { return [:] }
            recordWorkspace(event.workspace, on: &task)

            // The agent was asked to file this chat and has not. Send it back to do so, once.
            if canHold, task.autoCreated, !marks.has(.reminded, session) {
                marks.set(.reminded, session, true)
                _ = try? store.save(task, now: now())
                return ["decision": "block", "reason": Self.filingReminder(session: session, cli: cliPath)]
            }

            // An agent that already marked itself done or blocked knows better than this hook.
            if task.status == .working || task.awaitingApproval {
                switch outcome {
                case "aborted":
                    task.status = .idle
                    task.attention = nil
                case "error":
                    task.status = .needsAttention
                    task.attention = "Agent stopped with an error"
                default:
                    task.status = .needsAttention
                    task.attention = "Agent finished its turn"
                }
            }
            task.awaitingApproval = false
            _ = try? store.save(task, now: now())
            return [:]

        case .waitingOnUser(let reason, let approval):
            guard var task = task(for: session) else { return [:] }
            if approval {
                task.status = .needsAttention
                task.attention = reason
                task.awaitingApproval = true
            } else if task.status == .working {
                task.status = .needsAttention
                task.attention = reason
            } else {
                return [:]
            }
            _ = try? store.save(task, now: now())
            return [:]

        case .moved:
            // Runs after every tool call, so it writes only when there is something to undo.
            guard var task = task(for: session), task.awaitingApproval else { return [:] }
            task.status = .working
            task.attention = nil
            task.awaitingApproval = false
            _ = try? store.save(task, now: now())
            return [:]

        case .sessionEnded:
            if var task = task(for: session), task.status == .working || task.awaitingApproval {
                task.status = .idle
                task.attention = nil
                task.awaitingApproval = false
                _ = try? store.save(task, now: now())
            }
            marks.set(.ignore, session, false)
            marks.set(.reminded, session, false)
            return [:]
        }
    }

    private var marks: SessionMarks { SessionMarks(store: store) }

    private func promptSubmitted(_ event: Event, prompt: String) {
        if var task = task(for: event.session) {
            task.status = .working
            task.attention = nil
            task.awaitingApproval = false
            recordWorkspace(event.workspace, on: &task)
            _ = try? store.save(task, now: now())
            return
        }

        // No task yet: show the chat on the board straight away. The agent re-files it
        // (see `SessionLinker`) once it has looked at the existing tasks.
        let title = prompt.truncatedTitle()
        var task = TaskItem(
            id: "",
            title: title.isEmpty ? "New \(event.kind.displayName) agent" : title,
            status: .working,
            autoCreated: true,
            body: prompt.isEmpty ? "" : "Started from this prompt:\n\n" + Self.quoted(prompt)
        )
        task.agent = AgentLink(kind: event.kind, session: event.session)
        recordWorkspace(event.workspace, on: &task)
        _ = try? store.create(task, now: now())
    }

    private func recordWorkspace(_ workspace: String?, on task: inout TaskItem) {
        guard let workspace, !workspace.isEmpty else { return }
        task.workspace = workspace
        if let branch = branchLookup(workspace) {
            task.branch = branch
        }
    }

    func task(for session: String) -> TaskItem? {
        store.loadAll().first { $0.agent?.session == session }
    }

    /// Claude lets a SessionStart hook add variables to the shell its Bash tool uses.
    private func exportSessionToClaudeShell(_ session: String) {
        guard let path = environment["CLAUDE_ENV_FILE"], !path.isEmpty,
              let handle = FileHandle(forWritingAtPath: path)
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("export TASKBOARD_SESSION='\(session)'\n".utf8))
    }

    // MARK: - Text

    static func quoted(_ prompt: String) -> String {
        let clipped = prompt.count > 2000 ? String(prompt.prefix(2000)) + "…" : prompt
        return clipped.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
    }

    private static func quotedTool(_ cli: String) -> String {
        cli.contains(" ") ? "\"\(cli)\"" : cli
    }

    /// The standing instructions handed to every new agent chat.
    public static func agentInstructions(session: String, cli: String) -> String {
        let tool = quotedTool(cli)
        return """
        This machine runs Task Board, a menu bar board that shows what every agent is working on. \
        This chat is already on it, as a placeholder titled with the user's first words. \
        Replace that placeholder before you start on the user's request. This chat's session id is \(session).

        1. Run `\(tool) list` to see the existing tasks and subtasks.
        2. Then run exactly one of these:
           - `\(tool) attach <task-id> --session \(session)` when this chat continues an existing task or subtask.
           - `\(tool) add "<title>" --parent <task-id> --session \(session)` when this is a new piece of work under an existing top-level task.
           - `\(tool) add "<title>" --session \(session)` when it is unrelated to every existing task.
           - `\(tool) dismiss --session \(session)` when the user only wants a quick answer and there is nothing to track.
           Reviews, investigations and research are work: file them. A title says what is being done in at most \(TaskItem.maxTitleLength) characters.
        3. After you open a pull request, run `\(tool) update --pr <url> --session \(session)`. \
        If the work belongs to a Jira issue, add `--jira <KEY>`.
        4. When the task is completely finished, run `\(tool) status done --session \(session)`. \
        If you are blocked on the user, run `\(tool) status needs-attention --reason "<why>" --session \(session)`.

        Run each of these commands as its own shell call, never joined to another command with && or ;. \
        If one is refused, run it once more by itself. If it is refused again, tell the user in one line \
        that Task Board could not be updated. Otherwise do this quietly: do not mention Task Board to the user.
        """
    }

    /// What an agent is told when it tries to finish a turn without having filed its chat.
    static func filingReminder(session: String, cli: String) -> String {
        let tool = quotedTool(cli)
        return """
        This chat is still an unfiled placeholder on Task Board. Before you finish, run `\(tool) list` \
        if you have not, then exactly one of: `\(tool) attach <task-id> --session \(session)`, \
        `\(tool) add "<title>" --parent <task-id> --session \(session)`, \
        `\(tool) add "<title>" --session \(session)`, or `\(tool) dismiss --session \(session)` \
        if this chat was only a quick question. Run it as its own shell call, not joined to another \
        command. Then end your turn without mentioning this.
        """
    }
}

/// How an agent files its chat under the right task, replacing the stand-in made from its prompt.
public struct SessionLinker {
    public let store: TaskStore
    /// The app to assume for a session no task mentions yet.
    public let defaultKind: AgentKind
    public var now: () -> Date = Date.init

    public init(store: TaskStore, defaultKind: AgentKind = .cursor) {
        self.store = store
        self.defaultKind = defaultKind
    }

    private func standIn(for session: String, in tasks: [TaskItem]) -> TaskItem? {
        tasks.first { $0.agent?.session == session && $0.autoCreated }
    }

    /// A session keeps the app it was first seen in, whichever task it moves to.
    private func link(for session: String, in tasks: [TaskItem]) -> AgentLink {
        tasks.first { $0.agent?.session == session }?.agent ?? AgentLink(kind: defaultKind, session: session)
    }

    /// Takes the chat off every task except `keep`. A chat works on one task at a time.
    private func release(_ session: String, in tasks: [TaskItem], keep: String?) throws {
        for var other in tasks where other.agent?.session == session && other.id != keep && !other.autoCreated {
            other.agent = nil
            other.awaitingApproval = false
            if other.status == .working { other.status = .idle }
            try store.save(other, now: now())
        }
    }

    /// Points an existing task at this chat. The chat's stand-in task, if any, is removed.
    @discardableResult
    public func attach(taskID: String, session: String) throws -> TaskItem {
        let tasks = store.loadAll()
        guard var target = tasks.first(where: { $0.id == taskID }) else { throw TaskStoreError.notFound(taskID) }
        let link = link(for: session, in: tasks)

        if let placeholder = standIn(for: session, in: tasks), placeholder.id != target.id {
            target.workspace = target.workspace ?? placeholder.workspace
            target.branch = placeholder.branch ?? target.branch
            try store.delete(id: placeholder.id)
        }
        try release(session, in: tasks, keep: target.id)

        target.agent = link
        target.autoCreated = false
        target.awaitingApproval = false
        target.status = .working
        target.attention = nil
        return try store.save(target, now: now())
    }

    /// Takes a chat that is not work off the board: its stand-in goes, and no new one is made
    /// for its later prompts. Returns false when the chat is filed under a real task, which stays.
    @discardableResult
    public func dismiss(session: String) throws -> Bool {
        let tasks = store.loadAll()
        if let placeholder = standIn(for: session, in: tasks) {
            try store.delete(id: placeholder.id)
        } else if tasks.contains(where: { $0.agent?.session == session }) {
            return false
        }
        SessionMarks(store: store).set(.ignore, session, true)
        return true
    }

    /// Creates a task for this chat. If the chat already has a stand-in, that file's contents are
    /// carried over, so the card keeps its place instead of flickering.
    @discardableResult
    public func add(_ draft: TaskItem, session: String?) throws -> TaskItem {
        var draft = draft
        guard let session, !session.isEmpty else { return try store.create(draft, now: now()) }

        let tasks = store.loadAll()
        draft.agent = link(for: session, in: tasks)
        if draft.status == .idle { draft.status = .working }

        guard var placeholder = standIn(for: session, in: tasks) else {
            try release(session, in: tasks, keep: nil)
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
