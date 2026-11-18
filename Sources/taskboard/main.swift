import Foundation
import TaskBoardCore

// The `taskboard` command line tool. The menu bar app only reads task files;
// this is how agents, Cursor hooks and you write them.

let usage = """
taskboard — manage the tasks shown by the Task Board menu bar app

USAGE
  taskboard list [--json]                 Show every task and subtask
  taskboard show <id>                     Print one task's markdown file
  taskboard add <title> [options]         Create a task
  taskboard attach <id>                   File the current agent chat under an existing task
  taskboard update [<id>] [options]       Change a task
  taskboard status [<id>] <status>        Set the status: idle, working, needs-attention, done
  taskboard remove <id>                   Delete a task file
  taskboard path                          Print the tasks folder

  taskboard hook                          Handle a Cursor hook event (JSON on stdin)
  taskboard install-cursor-hooks          Add the hooks to ~/.cursor/hooks.json
  taskboard uninstall-cursor-hooks        Remove them again

OPTIONS (add, update)
  --title <text>       At most \(TaskItem.maxTitleLength) characters
  --parent <id>        Make it a subtask of a top-level task ("none" to detach)
  --column <name>      Pin it to a column ("auto" to let it move on its own)
  --status <status>    idle, working, needs-attention, done
  --reason <text>      Why it needs attention
  --jira <KEY>         Link a Jira issue ("none" to unlink)
  --pr <url>           Link a GitHub pull request ("none" to unlink)
  --body <markdown>    Replace the description
  --note <markdown>    Append a paragraph to the description
  --session <id>       The agent chat this call is about. Defaults to $TASKBOARD_SESSION.
                       With a session, `update` and `status` need no task id.
"""

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Splits arguments into positionals and `--name value` options.
struct Arguments {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let flagNames: Set<String> = ["json", "help", "print"]

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            if argument.hasPrefix("--"), argument.count > 2 {
                var name = String(argument.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    options[String(name[..<equals])] = String(name[name.index(after: equals)...])
                } else if Self.flagNames.contains(name) {
                    flags.insert(name)
                } else {
                    guard index + 1 < raw.count else { throw Failure("Missing a value for --\(name).") }
                    name = name.replacingOccurrences(of: "_", with: "-")
                    options[name] = raw[index + 1]
                    index += 1
                }
            } else {
                positionals.append(argument)
            }
            index += 1
        }
    }

    var session: String? {
        let value = options["session"] ?? ProcessInfo.processInfo.environment["TASKBOARD_SESSION"]
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

let config = BoardConfig.load()
let store = TaskStore(config: config)

func validatedTitle(_ raw: String) throws -> String {
    let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw Failure("A title cannot be empty.") }
    guard title.count <= TaskItem.maxTitleLength else {
        throw Failure("Titles are at most \(TaskItem.maxTitleLength) characters; this one is \(title.count). Shorten it.")
    }
    return title
}

func parseStatus(_ raw: String) throws -> TaskStatus {
    guard let status = TaskStatus(lenient: raw) else {
        throw Failure("Unknown status '\(raw)'. Use idle, working, needs-attention or done.")
    }
    return status
}

func resolveColumn(_ raw: String) throws -> String? {
    if raw.lowercased() == "auto" { return nil }
    guard let column = config.column(id: raw) else {
        let names = config.columns.map(\.name).joined(separator: ", ")
        throw Failure("No column named '\(raw)'. Columns: \(names).")
    }
    return column.id
}

func requireParent(_ id: String) throws -> String {
    guard store.task(id: id) != nil else { throw Failure("No task with id '\(id)' to use as the parent.") }
    return id
}

/// "none" clears a link.
func optionalLink(_ raw: String) -> String? {
    ["none", "null", "-", ""].contains(raw.lowercased()) ? nil : raw
}

/// The task a command is about: an explicit id, or the one the current agent chat is filed under.
func targetTask(id: String?, session: String?) throws -> TaskItem {
    if let id { return try store.require(id: id) }
    guard let session else {
        throw Failure("Give a task id, or pass --session <id> to act on the current agent chat's task.")
    }
    guard let task = store.loadAll().first(where: { $0.cursorAgent == session }) else {
        throw Failure("No task is linked to session \(session) yet. Run `taskboard add` or `taskboard attach` first.")
    }
    return task
}

func applyOptions(_ arguments: Arguments, to task: inout TaskItem) throws {
    if let title = arguments.options["title"] { task.title = try validatedTitle(title) }
    if let parent = arguments.options["parent"] {
        task.parent = try optionalLink(parent).map(requireParent)
        if task.parent == task.id { throw Failure("A task cannot be its own parent.") }
    }
    if let column = arguments.options["column"] { task.column = try resolveColumn(column) }
    if let status = arguments.options["status"] {
        task.status = try parseStatus(status)
        if task.status != .needsAttention { task.attention = nil }
    }
    if let reason = arguments.options["reason"] { task.attention = optionalLink(reason) }
    if let jira = arguments.options["jira"] { task.jira = optionalLink(jira)?.uppercased() }
    if let pr = arguments.options["pr"] { task.pr = optionalLink(pr) }
    if let body = arguments.options["body"] { task.body = body }
    if let note = arguments.options["note"] {
        task.body = task.body.isEmpty ? note : task.body + "\n\n" + note
    }
}

func describe(_ task: TaskItem) -> String {
    var line = "\(task.id)  [\(task.status.rawValue)]  \(task.title)"
    if let jira = task.jira { line += "  (\(jira))" }
    if task.pr != nil { line += "  (PR)" }
    return line
}

func listTasks(json: Bool) throws {
    let nodes = BoardBuilder.tree(tasks: store.loadAll()).sorted { $0.lastActivity > $1.lastActivity }
    if json {
        func encode(_ task: TaskItem) -> [String: Any] {
            var object: [String: Any] = ["id": task.id, "title": task.title, "status": task.status.rawValue]
            object["column"] = task.column
            object["jira"] = task.jira
            object["pr"] = task.pr
            object["cursor_agent"] = task.cursorAgent
            return object
        }
        let payload = nodes.map { node -> [String: Any] in
            var object = encode(node.task)
            object["subtasks"] = node.subtasks.map(encode)
            return object
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }
    if nodes.isEmpty {
        print("No tasks yet. Create one with: taskboard add \"<title>\"")
        return
    }
    for node in nodes {
        print(describe(node.task))
        for subtask in node.subtasks {
            print("    " + describe(subtask))
        }
    }
}

func run(_ rawArguments: [String]) throws {
    guard let command = rawArguments.first else {
        print(usage)
        return
    }
    let arguments = try Arguments(Array(rawArguments.dropFirst()))
    if arguments.flags.contains("help") {
        print(usage)
        return
    }

    switch command {
    case "help", "--help", "-h":
        print(usage)

    case "list", "ls":
        try listTasks(json: arguments.flags.contains("json"))

    case "show":
        guard let id = arguments.positionals.first else { throw Failure("Usage: taskboard show <id>") }
        print(try store.require(id: id).markdown(), terminator: "")

    case "path":
        print(store.directory.path)

    case "add":
        let rawTitle = arguments.positionals.first ?? arguments.options["title"]
        guard let rawTitle else { throw Failure("Usage: taskboard add <title> [options]") }
        var draft = TaskItem(id: "", title: try validatedTitle(rawTitle))
        try applyOptions(arguments, to: &draft)
        let created = try SessionLinker(store: store).add(draft, session: arguments.session)
        print("Created \(created.id)")

    case "attach":
        guard let id = arguments.positionals.first else { throw Failure("Usage: taskboard attach <id> --session <id>") }
        guard let session = arguments.session else {
            throw Failure("attach needs the agent chat's id: pass --session <id>.")
        }
        let task = try SessionLinker(store: store).attach(taskID: id, session: session)
        print("Attached this chat to \(task.id): \(task.title)")

    case "update", "edit":
        var task = try targetTask(id: arguments.positionals.first, session: arguments.session)
        try applyOptions(arguments, to: &task)
        try store.save(task)
        print("Updated \(task.id)")

    case "status":
        // `status <status>` (current chat's task) or `status <id> <status>`.
        let positionals = arguments.positionals
        guard let rawStatus = positionals.last, (1...2).contains(positionals.count) else {
            throw Failure("Usage: taskboard status [<id>] <idle|working|needs-attention|done> [--reason <text>]")
        }
        var task = try targetTask(id: positionals.count == 2 ? positionals[0] : nil, session: arguments.session)
        task.status = try parseStatus(rawStatus)
        task.attention = task.status == .needsAttention ? arguments.options["reason"] : nil
        try store.save(task)
        print("\(task.id) is now \(task.status.rawValue)")

    case "remove", "rm":
        guard let id = arguments.positionals.first else { throw Failure("Usage: taskboard remove <id>") }
        let orphans = store.loadAll().filter { $0.parent == id }
        guard orphans.isEmpty else {
            throw Failure("\(id) still has \(orphans.count) subtask(s). Remove or re-parent them first.")
        }
        try store.delete(id: id)
        print("Removed \(id)")

    case "hook":
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        let hooks = CursorHooks(store: store, cliPath: CursorInstaller.cliLink.path)
        let response = hooks.handle(payload: payload)
        FileHandle.standardOutput.write(response)

        // Diagnosis: `touch ~/.taskboard/hooks.log` and every hook call is recorded there.
        let log = BoardPaths.home.appendingPathComponent("hooks.log")
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            let stamp = ISO8601DateFormatter().string(from: Date())
            let entry = "\(stamp)\nin:  \(String(decoding: payload, as: UTF8.self))\nout: \(String(decoding: response, as: UTF8.self))\n\n"
            try? handle.write(contentsOf: Data(entry.utf8))
        }

    case "install-cursor-hooks":
        // Hooks call the CLI through a stable link, so they survive the app being moved.
        let binary = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        if arguments.flags.contains("print") {
            let merged = CursorInstaller.merged(existing: [:], cliPath: CursorInstaller.cliLink.path)
            let data = try JSONSerialization.data(
                withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            print(String(decoding: data, as: UTF8.self))
            return
        }
        try CursorInstaller.linkCLI(from: binary)
        try CursorInstaller.install()
        print("Installed Cursor hooks in \(CursorInstaller.hooksFile.path)")
        print("They call \(CursorInstaller.cliLink.path) -> \(binary.path)")

    case "uninstall-cursor-hooks":
        try CursorInstaller.uninstall()
        print("Removed Task Board hooks from \(CursorInstaller.hooksFile.path)")

    default:
        throw Failure("Unknown command '\(command)'. Run `taskboard help`.")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    // A hook must never fail the agent, whatever went wrong.
    if CommandLine.arguments.dropFirst().first == "hook" {
        print("{}")
        exit(0)
    }
    FileHandle.standardError.write(Data("taskboard: \(error)\n".utf8))
    exit(1)
}
