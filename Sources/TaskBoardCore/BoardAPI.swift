import Foundation
import Security

public struct APIRequest {
    public var method: String
    /// The path without its query, e.g. `/v1/tasks/fix-login`.
    public var path: String
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct APIResponse {
    public var status: Int
    /// `nil` for a response with no body.
    public var json: Any?

    public init(status: Int, json: Any? = nil) {
        self.status = status
        self.json = json
    }

    static func error(_ status: Int, _ message: String) -> APIResponse {
        APIResponse(status: status, json: ["error": message])
    }

    public var body: Data {
        guard let json else { return Data() }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? JSONSerialization.data(withJSONObject: json, options: options)) ?? Data("{}".utf8)) + Data("\n".utf8)
    }
}

/// The secret a caller must present. It lives in a file only the user can read, so anything
/// running as the user can use the API, and a web page cannot.
public enum APIToken {
    public static var file: URL { BoardPaths.home.appendingPathComponent("api-token") }

    public static func read(from file: URL = file) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Returns the existing token, or makes one.
    public static func loadOrCreate(at file: URL = file) throws -> String {
        if let existing = read(from: file) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TaskEditError("Could not generate an API token.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created private from the start, rather than written and then locked down.
        guard FileManager.default.createFile(
            atPath: file.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600]
        ) else { throw TaskEditError("Could not write \(file.path).") }
        return token
    }
}

/// The HTTP API, with the network taken away: a request goes in, a response comes out.
///
///     GET    /v1/health                         is the app there? (no token needed)
///     GET    /v1/tasks                          every task, subtasks nested
///     POST   /v1/tasks                          create one; with "session", file that chat under it
///     GET    /v1/tasks/<id>
///     PATCH  /v1/tasks/<id>                     change fields; null clears one
///     DELETE /v1/tasks/<id>
///     GET    /v1/sessions/<session>             the task a chat is filed under
///     PATCH  /v1/sessions/<session>             change that task, without knowing its id
///     POST   /v1/sessions/<session>/attach      {"task": "<id>"}: file the chat under an existing task
///     POST   /v1/sessions/<session>/dismiss     the chat is not work; take it off the board
public struct BoardAPI {
    public let store: TaskStore
    public let token: String
    /// Read on every request, so changes made in Settings apply at once.
    public let config: () -> BoardConfig
    public var now: () -> Date = Date.init

    public init(store: TaskStore, token: String, config: @escaping () -> BoardConfig) {
        self.store = store
        self.token = token
        self.config = config
    }

    public func respond(to request: APIRequest) -> APIResponse {
        // A browser sends Origin with every cross-site request that could change anything, and a
        // page that has re-pointed its own domain at this machine still names that domain in Host.
        // Refusing both keeps web pages out even before the token is checked.
        if request.headers["origin"] != nil {
            return .error(403, "Requests from web pages are not accepted.")
        }
        guard Self.isLocal(host: request.headers["host"]) else {
            return .error(403, "This API answers only to localhost.")
        }

        let parts = request.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.first == "v1" else { return .error(404, "No such path. Paths start with /v1/.") }
        if parts == ["v1", "health"] {
            return request.method == "GET" ? APIResponse(status: 200, json: ["ok": true, "app": "Task Board"]) : .error(405, "Use GET.")
        }

        guard request.headers["authorization"] == "Bearer \(token)" else {
            return .error(401, "Missing or wrong token. Send the header  Authorization: Bearer <contents of \(Self.tokenPathForMessages)>.")
        }

        do {
            return try route(request.method, Array(parts.dropFirst()), body: request.body)
        } catch let error as TaskEditError {
            return .error(400, error.description)
        } catch let error as TaskStoreError {
            if case .notFound = error { return .error(404, error.description) }
            return .error(400, error.description)
        } catch {
            return .error(500, "\(error)")
        }
    }

    private static var tokenPathForMessages: String {
        (APIToken.file.path as NSString).abbreviatingWithTildeInPath
    }

    static func isLocal(host: String?) -> Bool {
        guard var host = host?.lowercased() else { return false }
        if host.hasPrefix("[") {
            host = String(host.prefix { $0 != "]" }) + "]"
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return ["127.0.0.1", "localhost", "[::1]"].contains(host)
    }

    // MARK: - Routes

    private func route(_ method: String, _ parts: [String], body: Data) throws -> APIResponse {
        switch (parts.first, parts.count) {
        case ("tasks", 1):
            switch method {
            case "GET":
                let nodes = BoardBuilder.tree(tasks: store.loadAll()).sorted { $0.lastActivity > $1.lastActivity }
                return APIResponse(status: 200, json: nodes.map { Self.json($0.task, subtasks: $0.subtasks) })
            case "POST":
                return try create(fields(body))
            default:
                return .error(405, "Use GET or POST.")
            }

        case ("tasks", 2):
            let id = parts[1]
            switch method {
            case "GET":
                return APIResponse(status: 200, json: try taskJSON(id: id))
            case "PATCH":
                var task = try store.require(id: id)
                try TaskEdit.apply(try changes(fields(body)), to: &task, config: config(), store: store)
                try store.save(task, now: now())
                return APIResponse(status: 200, json: try taskJSON(id: id))
            case "DELETE":
                let subtasks = store.loadAll().filter { $0.parent == id }
                guard subtasks.isEmpty else {
                    return .error(409, "\(id) still has \(subtasks.count) subtask(s). Remove or re-parent them first.")
                }
                try store.delete(id: id)
                return APIResponse(status: 204)
            default:
                return .error(405, "Use GET, PATCH or DELETE.")
            }

        case ("sessions", 2):
            let session = parts[1]
            guard var task = store.loadAll().first(where: { $0.agent?.session == session }) else {
                return .error(404, "No task is filed for session \(session). Create one with POST /v1/tasks and \"session\".")
            }
            switch method {
            case "GET":
                return APIResponse(status: 200, json: try taskJSON(id: task.id))
            case "PATCH":
                try TaskEdit.apply(try changes(fields(body)), to: &task, config: config(), store: store)
                try store.save(task, now: now())
                return APIResponse(status: 200, json: try taskJSON(id: task.id))
            default:
                return .error(405, "Use GET or PATCH.")
            }

        case ("sessions", 3):
            guard method == "POST" else { return .error(405, "Use POST.") }
            let session = parts[1]
            let input = try fields(body)
            let linker = SessionLinker(store: store, defaultKind: try agentKind(input) ?? config().agent)
            switch parts[2] {
            case "attach":
                guard let id = input["task"] as? String else {
                    return .error(400, "Say which task: {\"task\": \"<id>\"}.")
                }
                let task = try linker.attach(taskID: id, session: session)
                return APIResponse(status: 200, json: try taskJSON(id: task.id))
            case "dismiss":
                guard try linker.dismiss(session: session) else {
                    return .error(409, "This chat is filed under a task, so it stays on the board. Set its status to done instead.")
                }
                return APIResponse(status: 204)
            default:
                return .error(404, "No such path.")
            }

        default:
            return .error(404, "No such path.")
        }
    }

    private func create(_ input: [String: Any]) throws -> APIResponse {
        guard let title = input["title"] as? String else {
            return .error(400, "A new task needs a \"title\".")
        }
        var draft = TaskItem(id: "", title: try TaskEdit.validatedTitle(title))
        var rest = input
        rest["title"] = nil
        try TaskEdit.apply(try changes(rest), to: &draft, config: config(), store: store)

        let session = (input["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let linker = SessionLinker(store: store, defaultKind: try agentKind(input) ?? config().agent)
        let created = try linker.add(draft, session: session)
        return APIResponse(status: 201, json: try taskJSON(id: created.id))
    }

    // MARK: - JSON in

    private func fields(_ body: Data) throws -> [String: Any] {
        if body.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TaskEditError("The request body must be a JSON object.")
        }
        return object
    }

    /// The task fields in a request, as changes. `session`, `agent` and `task` are about filing, not fields.
    private func changes(_ input: [String: Any]) throws -> [String: String?] {
        var changes: [String: String?] = [:]
        for (key, value) in input where !["session", "agent", "task"].contains(key) {
            switch value {
            case let text as String: changes[key] = text
            case is NSNull: changes[key] = .some(nil)
            default: throw TaskEditError("\"\(key)\" must be a string or null.")
            }
        }
        return changes
    }

    private func agentKind(_ input: [String: Any]) throws -> AgentKind? {
        guard let raw = input["agent"] as? String else { return nil }
        guard let kind = AgentKind(rawValue: raw.lowercased()) else {
            throw TaskEditError("\"agent\" is either \"cursor\" or \"claude\".")
        }
        return kind
    }

    // MARK: - JSON out

    private func taskJSON(id: String) throws -> [String: Any] {
        let tasks = store.loadAll()
        guard let task = tasks.first(where: { $0.id == id }) else { throw TaskStoreError.notFound(id) }
        let node = BoardBuilder.tree(tasks: tasks).first { $0.id == id }
        return Self.json(task, subtasks: node?.subtasks ?? [])
    }

    static func json(_ task: TaskItem, subtasks: [TaskItem] = []) -> [String: Any] {
        func orNull(_ value: String?) -> Any { value ?? NSNull() }
        var object: [String: Any] = [
            "id": task.id,
            "title": task.title,
            "status": task.status.rawValue,
            "reason": orNull(task.attention),
            "column": orNull(task.column),
            "parent": orNull(task.parent),
            "jira": orNull(task.jira),
            "pr": orNull(task.pr),
            "workspace": orNull(task.workspace),
            "branch": orNull(task.branch),
            "body": task.body,
            "created": orNull(task.created.map(DateCoding.string)),
            "updated": orNull(task.updated.map(DateCoding.string)),
            // True while the card is a stand-in made from a prompt, waiting for the agent to file it.
            "unfiled": task.autoCreated,
            "subtasks": subtasks.map { json($0) },
        ]
        if let agent = task.agent {
            object["agent"] = [
                "app": agent.kind.rawValue,
                "session": agent.session,
                "link": orNull(agent.url?.absoluteString),
            ]
        } else {
            object["agent"] = NSNull()
        }
        return object
    }
}
