import XCTest
@testable import TaskBoardCore

final class FrontMatterTests: XCTestCase {
    func testParsesFieldsAndBody() {
        let text = """
        ---
        id: fix-login
        title: "Fix: login redirect loop"
        status: working
        ---

        # Details

        Some **markdown**.
        """
        let task = TaskItem(markdown: text, fallbackID: "file-name")
        XCTAssertEqual(task.id, "fix-login")
        XCTAssertEqual(task.title, "Fix: login redirect loop")
        XCTAssertEqual(task.status, .working)
        XCTAssertEqual(task.body, "# Details\n\nSome **markdown**.")
    }

    func testFileWithoutFrontMatterUsesHeadingAndFileName() {
        let task = TaskItem(markdown: "# Ship the thing\n\nNotes.", fallbackID: "ship-it")
        XCTAssertEqual(task.id, "ship-it")
        XCTAssertEqual(task.title, "Ship the thing")
        XCTAssertEqual(task.status, .idle)
    }

    func testRoundTripKeepsUnknownKeysAndAwkwardValues() {
        let text = """
        ---
        id: a
        title: "He said \\"hi\\": #1"
        owner: someone
        labels:
          - one
          - two
        status: needs-attention
        ---

        Body
        """
        let first = TaskItem(markdown: text, fallbackID: "a")
        XCTAssertEqual(first.title, "He said \"hi\": #1")
        let written = first.markdown()
        XCTAssertTrue(written.contains("owner: someone"))
        XCTAssertTrue(written.contains("  - one"))
        let second = TaskItem(markdown: written, fallbackID: "a")
        XCTAssertEqual(second.title, first.title)
        XCTAssertEqual(second.status, .needsAttention)
        XCTAssertEqual(second.body, "Body")
        XCTAssertEqual(second.markdown(), written)
    }

    func testLenientStatusNames() {
        XCTAssertEqual(TaskStatus(lenient: "In Progress"), .working)
        XCTAssertEqual(TaskStatus(lenient: "needs_attention"), .needsAttention)
        XCTAssertEqual(TaskStatus(lenient: "TODO"), .idle)
        XCTAssertEqual(TaskStatus(lenient: "merged"), .done)
        XCTAssertNil(TaskStatus(lenient: "banana"))
    }

    func testTitleTruncation() {
        let long = "Add rate limiting to the token refresh endpoint so clients cannot hammer it"
        let short = long.truncatedTitle()
        XCTAssertLessThanOrEqual(short.count, TaskItem.maxTitleLength)
        XCTAssertTrue(short.hasSuffix("…"))
        XCTAssertEqual("  \nshort one\nsecond line".truncatedTitle(), "short one")
        XCTAssertEqual("<bash-input>swift test</bash-input>".truncatedTitle(), "swift test")
        XCTAssertEqual("Is a < b and b > c here?".truncatedTitle(), "Is a < b and b > c here?")
    }

    func testAgentDeepLinks() {
        let id = "617e7b4c-1c4b-4cf2-8a98-d881f2dc99b5"
        XCTAssertEqual(
            TaskItem(id: "a", title: "A", cursorAgent: id).agentURL?.absoluteString,
            "cursor://anysphere.cursor-deeplink/agent?id=\(id)"
        )
        // A session in the Claude desktop app, and one started in the `claude` command.
        XCTAssertEqual(
            TaskItem(id: "a", title: "A", claudeSession: "local_\(id)").agentURL?.absoluteString,
            "claude://claude.ai/epitaxy/local_\(id)"
        )
        XCTAssertEqual(
            TaskItem(id: "a", title: "A", claudeSession: id).agentURL?.absoluteString,
            "claude://resume?session=\(id)"
        )
        XCTAssertNil(TaskItem(id: "b", title: "B").agentURL)
    }

    func testAgentLinkRoundTripsThroughTheFile() {
        let claude = TaskItem(markdown: TaskItem(id: "a", title: "A", claudeSession: "local_1").markdown(), fallbackID: "a")
        XCTAssertEqual(claude.agent, AgentLink(kind: .claude, session: "local_1"))
        XCTAssertTrue(claude.markdown().contains("claude_session: local_1"))
        let cursor = TaskItem(markdown: "---\ncursor_agent: chat-9\n---\n", fallbackID: "b")
        XCTAssertEqual(cursor.agent, AgentLink(kind: .cursor, session: "chat-9"))
    }
}

final class BoardTests: XCTestCase {
    let config = BoardConfig.default

    func pr(_ state: PullRequestInfo.State, _ checks: PullRequestInfo.Checks = .none, review: String? = nil) -> PullRequestInfo {
        PullRequestInfo(url: "u", state: state, checks: checks, failingChecks: checks == .failing ? ["lint"] : [], reviewDecision: review)
    }

    func testTreeIsOneLevelDeepAndKeepsOrphans() {
        let tasks = [
            TaskItem(id: "root", title: "Root"),
            TaskItem(id: "child", title: "Child", parent: "root"),
            TaskItem(id: "grandchild", title: "Grandchild", parent: "child"),
            TaskItem(id: "orphan", title: "Orphan", parent: "missing"),
        ]
        let tree = BoardBuilder.tree(tasks: tasks)
        XCTAssertEqual(Set(tree.map(\.id)), ["root", "orphan"])
        XCTAssertEqual(Set(tree.first { $0.id == "root" }!.subtasks.map(\.id)), ["child", "grandchild"])
    }

    func testParentCycleDoesNotHang() {
        let tasks = [
            TaskItem(id: "a", title: "A", parent: "b"),
            TaskItem(id: "b", title: "B", parent: "a"),
        ]
        XCTAssertEqual(BoardBuilder.tree(tasks: tasks).flatMap { [$0.task] + $0.subtasks }.count, 2)
    }

    func testSubtasksSurviveAParentWithADanglingParent() {
        let tasks = [
            TaskItem(id: "root", title: "Root", parent: "deleted-long-ago"),
            TaskItem(id: "child", title: "Child", parent: "root"),
        ]
        let tree = BoardBuilder.tree(tasks: tasks)
        XCTAssertEqual(tree.map(\.id), ["root"])
        XCTAssertEqual(tree.first?.subtasks.map(\.id), ["child"])
    }

    func testOwnStatusFoldsInPullRequest() {
        var task = TaskItem(id: "a", title: "A", pr: "u")
        var remote = RemoteState(pullRequests: ["u": pr(.open, .failing)])
        XCTAssertEqual(StatusResolver.own(task, remote: remote).status, .needsAttention)
        XCTAssertEqual(StatusResolver.own(task, remote: remote).reasons, ["CI is failing: lint"])

        // A busy agent is presumably fixing it.
        task.status = .working
        XCTAssertEqual(StatusResolver.own(task, remote: remote).status, .working)

        task.status = .idle
        remote.pullRequests["u"] = pr(.open, .passing, review: "CHANGES_REQUESTED")
        XCTAssertEqual(StatusResolver.own(task, remote: remote).status, .needsAttention)

        remote.pullRequests["u"] = pr(.merged)
        XCTAssertEqual(StatusResolver.own(task, remote: remote).status, .done)

        remote.pullRequests["u"] = pr(.open, .passing)
        XCTAssertEqual(StatusResolver.own(task, remote: remote).status, .idle)
    }

    func testRollupSummarisesSubtasks() {
        let parent = TaskItem(id: "p", title: "Parent")
        func node(_ statuses: [TaskStatus]) -> TaskNode {
            TaskNode(task: parent, subtasks: statuses.enumerated().map {
                TaskItem(id: "s\($0.offset)", title: "Sub \($0.offset)", status: $0.element)
            })
        }
        let remote = RemoteState()
        XCTAssertEqual(StatusResolver.rollup(node([.done, .working, .needsAttention]), remote: remote).status, .needsAttention)
        XCTAssertEqual(StatusResolver.rollup(node([.done, .working, .idle]), remote: remote).status, .working)
        XCTAssertEqual(StatusResolver.rollup(node([.done, .done]), remote: remote).status, .done)
        XCTAssertEqual(StatusResolver.rollup(node([.done, .idle]), remote: remote).status, .idle)
        XCTAssertEqual(StatusResolver.rollup(node([]), remote: remote).status, .idle)

        let reasons = StatusResolver.rollup(node([.needsAttention]), remote: remote).reasons
        XCTAssertEqual(reasons, ["Sub 0: Agent is waiting on you"])
    }

    func testAutomaticColumnPlacement() {
        let remote = RemoteState(pullRequests: [
            "open": PullRequestInfo(url: "open", state: .open),
            "merged": PullRequestInfo(url: "merged", state: .merged),
        ])
        let tasks = [
            TaskItem(id: "untouched", title: "Untouched"),
            TaskItem(id: "has-agent", title: "Agent", cursorAgent: "chat"),
            TaskItem(id: "in-review", title: "Review", pr: "open"),
            TaskItem(id: "shipped", title: "Shipped", pr: "merged"),
            TaskItem(id: "pinned", title: "Pinned", column: "Backlog", status: .done),
            TaskItem(id: "parent", title: "Parent"),
            TaskItem(id: "busy-child", title: "Busy child", status: .working, parent: "parent"),
        ]
        let columns = BoardBuilder.columns(tasks: tasks, config: config, remote: remote)
        func ids(_ column: String) -> Set<String> {
            Set(columns.first { $0.id == column }!.nodes.map(\.id))
        }
        XCTAssertEqual(ids("backlog"), ["untouched", "pinned"])
        XCTAssertEqual(ids("in-progress"), ["has-agent", "parent"])
        XCTAssertEqual(ids("in-review"), ["in-review"])
        XCTAssertEqual(ids("done"), ["shipped"])
    }

    func testUnknownColumnFallsBackToFirst() {
        let tasks = [TaskItem(id: "a", title: "A", column: "no-such-column")]
        let columns = BoardBuilder.columns(tasks: tasks, config: config, remote: RemoteState())
        XCTAssertEqual(columns.first?.nodes.map(\.id), ["a"])
    }

    func testConfigDecodingFillsDefaults() throws {
        let config = try JSONDecoder().decode(BoardConfig.self, from: Data(#"{"layout":"list"}"#.utf8))
        XCTAssertEqual(config.layout, .list)
        XCTAssertEqual(config.columns, BoardConfig.default.columns)
        XCTAssertEqual(config.column(id: "In Progress")?.id, "in-progress")
    }
}

final class GitHubAndJiraTests: XCTestCase {
    func testParsesPullRequestChecks() {
        let json = """
        {"number": 42, "title": "Fix it", "url": "https://github.com/o/r/pull/42", "state": "OPEN",
         "isDraft": false, "reviewDecision": "",
         "statusCheckRollup": [
           {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"},
           {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE"},
           {"__typename": "CheckRun", "name": "e2e", "status": "IN_PROGRESS", "conclusion": ""},
           {"__typename": "StatusContext", "context": "deploy/preview", "state": "SUCCESS"}
         ]}
        """
        let info = GitHub.parsePullRequest(json: Data(json.utf8), url: "x")
        XCTAssertEqual(info?.state, .open)
        XCTAssertEqual(info?.checks, .failing)
        XCTAssertEqual(info?.failingChecks, ["lint"])
        XCTAssertEqual(info?.number, 42)
        XCTAssertNil(info?.reviewDecision)
    }

    func testPendingPassingAndMergedStates() {
        func parse(_ body: String) -> PullRequestInfo? {
            GitHub.parsePullRequest(json: Data(body.utf8), url: "x")
        }
        XCTAssertEqual(parse(#"{"state":"OPEN","isDraft":true,"statusCheckRollup":[{"name":"a","status":"QUEUED","conclusion":""}]}"#)?.checks, .pending)
        XCTAssertEqual(parse(#"{"state":"OPEN","isDraft":true,"statusCheckRollup":[]}"#)?.state, .draft)
        XCTAssertEqual(parse(#"{"state":"OPEN","statusCheckRollup":[{"name":"a","status":"COMPLETED","conclusion":"SKIPPED"}]}"#)?.checks, .passing)
        XCTAssertEqual(parse(#"{"state":"MERGED","statusCheckRollup":[]}"#)?.state, .merged)
        XCTAssertNil(parse("not json"))
    }

    func testGitHubServerAcceptsHostsAndURLs() throws {
        XCTAssertEqual(GitHub.normalizeHost(nil), "github.com")
        XCTAssertEqual(GitHub.normalizeHost("  "), "github.com")
        XCTAssertEqual(GitHub.normalizeHost("github.example.com"), "github.example.com")
        XCTAssertEqual(GitHub.normalizeHost("https://GitHub.Example.com/org/repo"), "github.example.com")
        XCTAssertEqual(GitHub.host(ofPullRequest: "https://github.example.com/org/repo/pull/7"), "github.example.com")

        let config = try JSONDecoder().decode(BoardConfig.self, from: Data(#"{"githubHost":"https://github.example.com/"}"#.utf8))
        XCTAssertEqual(config.githubHostName, "github.example.com")
        XCTAssertEqual(BoardConfig.default.githubHostName, "github.com")
    }

    func testDoctorReportsWhatIsMissingWithoutTouchingTheNetwork() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("taskboard-doctor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskStore(directory: home.appendingPathComponent("tasks"))
        var config = BoardConfig.default
        config.githubEnabled = false
        config.apiEnabled = false
        var doctor = Doctor(config: config, store: store)
        doctor.hooksFile = home.appendingPathComponent("hooks.json")
        doctor.cliLink = home.appendingPathComponent("bin/taskboard")

        var checks = await doctor.run()
        XCTAssertEqual(checks.first { $0.area == "Tasks" }?.outcome, .failure)
        XCTAssertEqual(checks.filter { $0.area == "Cursor" }.map(\.outcome), [.failure, .failure, .warning])
        XCTAssertEqual(checks.first { $0.area == "GitHub" }?.outcome, .warning)
        XCTAssertEqual(checks.first { $0.area == "API" }?.outcome, .warning)
        XCTAssertEqual(checks.first { $0.area == "Jira" }?.outcome, .warning)

        try store.create(TaskItem(id: "", title: "Has an agent", cursorAgent: "chat-1"))
        try HookInstaller.install(kind: .cursor, cliPath: doctor.cliLink.path, file: doctor.hooksFile)
        checks = await doctor.run()
        XCTAssertEqual(checks.first { $0.area == "Tasks" }?.outcome, .pass)
        XCTAssertEqual(checks.filter { $0.area == "Cursor" }.map(\.outcome), [.failure, .pass, .pass])
    }

    func testParsesJiraIssue() {
        let json = """
        {"key": "AUTH-101", "fields": {"summary": "Revamp auth",
         "status": {"name": "In Review", "statusCategory": {"key": "indeterminate"}}}}
        """
        let issue = JiraClient.parseIssue(json: Data(json.utf8))
        XCTAssertEqual(issue, JiraIssue(key: "AUTH-101", summary: "Revamp auth", statusName: "In Review", category: .inProgress))
    }

    func testJiraAuthHeaderDependsOnEmail() {
        let base = URL(string: "https://example.atlassian.net")!
        let cloud = JiraClient(baseURL: base, email: "me@example.com", token: "t").request(path: "rest/api/2/myself")
        XCTAssertEqual(cloud.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("me@example.com:t".utf8).base64EncodedString())
        XCTAssertEqual(cloud.httpMethod, "GET")
        let dataCenter = JiraClient(baseURL: base, email: nil, token: "t").request(path: "rest/api/2/myself")
        XCTAssertEqual(dataCenter.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }
}

final class CursorIntegrationTests: XCTestCase {
    var home: URL!
    var store: TaskStore!
    var hooks: AgentHooks!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("taskboard-tests-\(UUID().uuidString)")
        store = TaskStore(directory: home.appendingPathComponent("tasks"))
        hooks = AgentHooks(store: store, cliPath: "/opt/tb/taskboard")
        hooks.branchLookup = { _ in "feature/rate-limit" }
        // These tests may themselves run inside an agent session; do not inherit its ids.
        hooks.environment = [:]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    func send(_ event: [String: Any], from kind: AgentKind = .cursor) -> [String: Any] {
        let payload = try! JSONSerialization.data(withJSONObject: event)
        let output = hooks.handle(payload: payload, from: kind)
        if output.isEmpty { return [:] }
        return try! JSONSerialization.jsonObject(with: output) as! [String: Any]
    }

    func testSessionStartHandsTheAgentItsIDAndInstructions() {
        let output = send(["hook_event_name": "sessionStart", "conversation_id": "chat-1", "composer_mode": "agent"])
        XCTAssertEqual((output["env"] as? [String: String])?["TASKBOARD_SESSION"], "chat-1")
        let context = output["additional_context"] as? String ?? ""
        XCTAssertTrue(context.contains("/opt/tb/taskboard attach <task-id> --session chat-1"))
        XCTAssertTrue(context.contains("/opt/tb/taskboard dismiss --session chat-1"))
    }

    func testFirstPromptCreatesAStandInThatTheAgentRefiles() throws {
        try store.create(TaskItem(id: "", title: "Revamp auth"))
        let output = send([
            "hook_event_name": "beforeSubmitPrompt", "conversation_id": "chat-1",
            "workspace_roots": ["/work/app"],
            "prompt": "Add rate limiting to the token refresh endpoint so clients cannot hammer it",
        ])
        XCTAssertEqual(output["continue"] as? Bool, true)

        let standIn = try XCTUnwrap(store.loadAll().first { $0.agent?.session == "chat-1" })
        XCTAssertEqual(standIn.agent?.kind, .cursor)
        XCTAssertTrue(standIn.autoCreated)
        XCTAssertEqual(standIn.status, .working)
        XCTAssertEqual(standIn.workspace, "/work/app")
        XCTAssertEqual(standIn.branch, "feature/rate-limit")
        XCTAssertLessThanOrEqual(standIn.title.count, TaskItem.maxTitleLength)

        let filed = try SessionLinker(store: store).add(
            TaskItem(id: "", title: "Rate limit token refresh", parent: "revamp-auth"), session: "chat-1"
        )
        let all = store.loadAll()
        XCTAssertEqual(all.count, 2, "the stand-in is reused, not duplicated")
        XCTAssertEqual(filed.id, "rate-limit-token-refresh")
        XCTAssertEqual(filed.parent, "revamp-auth")
        XCTAssertFalse(filed.autoCreated)
        XCTAssertTrue(filed.body.contains("> Add rate limiting"))
    }

    func testAttachMovesTheChatOntoAnExistingTask() throws {
        try store.create(TaskItem(id: "", title: "Fix login redirect"))
        send(["hook_event_name": "beforeSubmitPrompt", "conversation_id": "chat-2", "prompt": "keep going on the login fix"])
        XCTAssertEqual(store.loadAll().count, 2)

        let task = try SessionLinker(store: store).attach(taskID: "fix-login-redirect", session: "chat-2")
        XCTAssertEqual(task.agent, AgentLink(kind: .cursor, session: "chat-2"))
        XCTAssertEqual(task.status, .working)
        XCTAssertEqual(store.loadAll().map(\.id), ["fix-login-redirect"])
    }

    func testStopAndNextPromptFlipTheStatus() throws {
        send(["hook_event_name": "beforeSubmitPrompt", "conversation_id": "chat-3", "prompt": "do the thing"])
        send(["hook_event_name": "stop", "conversation_id": "chat-3", "status": "completed"])
        var task = try XCTUnwrap(hooks.task(for: "chat-3"))
        XCTAssertEqual(task.status, .needsAttention)
        XCTAssertEqual(task.attention, "Agent finished its turn")

        send(["hook_event_name": "beforeSubmitPrompt", "conversation_id": "chat-3", "prompt": "and another thing"])
        task = try XCTUnwrap(hooks.task(for: "chat-3"))
        XCTAssertEqual(task.status, .working)
        XCTAssertNil(task.attention)
        XCTAssertEqual(store.loadAll().count, 1)

        // An agent that marked itself done is not overruled by the stop hook.
        task.status = .done
        try store.save(task)
        send(["hook_event_name": "stop", "conversation_id": "chat-3", "status": "completed"])
        XCTAssertEqual(hooks.task(for: "chat-3")?.status, .done)
    }

    func testAskChatsStayOffTheBoard() {
        XCTAssertTrue(send(["hook_event_name": "sessionStart", "conversation_id": "chat-4", "composer_mode": "ask"]).isEmpty)
        send(["hook_event_name": "beforeSubmitPrompt", "conversation_id": "chat-4", "prompt": "what does this do?"])
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testMalformedPayloadIsHarmless() {
        XCTAssertEqual(String(decoding: hooks.handle(payload: Data("nope".utf8), from: .cursor), as: UTF8.self), "{}")
        XCTAssertTrue(hooks.handle(payload: Data("nope".utf8), from: .claude).isEmpty)
    }

    func testNewSubtaskUnderASubtaskLandsOnTheTopLevelTask() throws {
        try store.create(TaskItem(id: "", title: "Root"))
        try store.create(TaskItem(id: "", title: "Child", parent: "root"))
        let nested = try store.create(TaskItem(id: "", title: "Nested", parent: "child"))
        XCTAssertEqual(nested.parent, "root")
    }

    func testInstallerMergesWithoutTouchingOtherHooks() {
        let existing: [String: Any] = [
            "version": 1,
            "hooks": ["stop": [["command": "./hooks/notify.sh"]], "afterFileEdit": [["command": "./fmt.sh"]]],
        ]
        let once = HookInstaller.merged(existing: existing, kind: .cursor, cliPath: "/a/taskboard")
        let twice = HookInstaller.merged(existing: once, kind: .cursor, cliPath: "/b/taskboard")
        let hooks = twice["hooks"] as! [String: [[String: String]]]
        XCTAssertEqual(hooks["stop"]!.map { $0["command"]! }, ["./hooks/notify.sh", "\"/b/taskboard\" hook cursor"])
        XCTAssertEqual(hooks["afterFileEdit"]!.count, 1)
        XCTAssertEqual(hooks["sessionStart"]!.count, 1)

        let cleaned = HookInstaller.removed(existing: twice, kind: .cursor)["hooks"] as! [String: [[String: String]]]
        XCTAssertEqual(cleaned["stop"]!.map { $0["command"]! }, ["./hooks/notify.sh"])
        XCTAssertNil(cleaned["sessionStart"])
    }

    // MARK: - Claude

    func testClaudeSessionStartAddsContextAndOtherEventsSayNothing() {
        let output = send(["hook_event_name": "SessionStart", "session_id": "uuid-1", "source": "startup", "cwd": "/work/app"], from: .claude)
        let specific = output["hookSpecificOutput"] as? [String: String]
        XCTAssertEqual(specific?["hookEventName"], "SessionStart")
        XCTAssertTrue(specific?["additionalContext"]?.contains("--session uuid-1") ?? false)

        let payload = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "UserPromptSubmit", "session_id": "uuid-1", "prompt": "do it"])
        XCTAssertTrue(hooks.handle(payload: payload, from: .claude).isEmpty, "Claude treats any output as something to act on")
    }

    func testClaudeTurnWithAPermissionPrompt() throws {
        func claude(_ event: String, _ extra: [String: Any] = [:]) {
            send(["hook_event_name": event, "session_id": "uuid-2", "cwd": "/work/app"].merging(extra) { $1 }, from: .claude)
        }
        claude("UserPromptSubmit", ["prompt": "Tidy up the build scripts"])
        var task = try XCTUnwrap(hooks.task(for: "uuid-2"))
        XCTAssertEqual(task.agent, AgentLink(kind: .claude, session: "uuid-2"))
        XCTAssertEqual(task.status, .working)
        XCTAssertEqual(task.workspace, "/work/app")

        // Stopped mid-turn on a permission prompt: it needs you now, not at the end of the turn.
        claude("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
        task = try XCTUnwrap(hooks.task(for: "uuid-2"))
        XCTAssertEqual(task.status, .needsAttention)
        XCTAssertEqual(task.attention, "Claude needs your permission to use Bash")

        // You approved and the tool ran: back to working.
        claude("PostToolUse", ["tool_name": "Bash"])
        task = try XCTUnwrap(hooks.task(for: "uuid-2"))
        XCTAssertEqual(task.status, .working)
        XCTAssertNil(task.attention)
        XCTAssertFalse(task.awaitingApproval)

        // Tool calls are otherwise ignored, so the file is not rewritten on every one.
        let before = try XCTUnwrap(task.updated)
        hooks.now = { before.addingTimeInterval(60) }
        claude("PostToolUse", ["tool_name": "Read"])
        XCTAssertEqual(hooks.task(for: "uuid-2")?.updated, before)

        try SessionLinker(store: store).add(TaskItem(id: "", title: "Tidy the build scripts"), session: "uuid-2")
        claude("Stop")
        XCTAssertEqual(hooks.task(for: "uuid-2")?.status, .needsAttention)
        XCTAssertEqual(hooks.task(for: "uuid-2")?.attention, "Agent finished its turn")
    }

    func testClaudeIsSentBackOnceToFileAnUnfiledChat() throws {
        func stop(active: Bool = false) -> [String: Any] {
            send(["hook_event_name": "Stop", "session_id": "uuid-7", "stop_hook_active": active], from: .claude)
        }
        send(["hook_event_name": "UserPromptSubmit", "session_id": "uuid-7", "prompt": "Review the telemetry change"], from: .claude)

        let held = stop()
        XCTAssertEqual(held["decision"] as? String, "block")
        XCTAssertTrue((held["reason"] as? String)?.contains("dismiss --session uuid-7") ?? false)
        XCTAssertEqual(hooks.task(for: "uuid-7")?.status, .working, "it is about to carry on")

        // Never twice: not on the second pass, and not on a later turn either.
        XCTAssertTrue(stop(active: true).isEmpty)
        XCTAssertEqual(hooks.task(for: "uuid-7")?.status, .needsAttention)
        send(["hook_event_name": "UserPromptSubmit", "session_id": "uuid-7", "prompt": "thanks"], from: .claude)
        XCTAssertTrue(stop().isEmpty)
    }

    func testAFiledChatIsNotHeld() throws {
        send(["hook_event_name": "UserPromptSubmit", "session_id": "uuid-8", "prompt": "Fix the build"], from: .claude)
        try SessionLinker(store: store, defaultKind: .claude).add(TaskItem(id: "", title: "Fix the build"), session: "uuid-8")
        XCTAssertTrue(send(["hook_event_name": "Stop", "session_id": "uuid-8"], from: .claude).isEmpty)
        XCTAssertEqual(hooks.task(for: "uuid-8")?.status, .needsAttention)
    }

    func testDismissTakesAQuestionOffTheBoardForGood() throws {
        send(["hook_event_name": "UserPromptSubmit", "session_id": "uuid-9", "prompt": "What does this flag do?"], from: .claude)
        XCTAssertEqual(store.loadAll().count, 1)
        XCTAssertTrue(try SessionLinker(store: store).dismiss(session: "uuid-9"))
        XCTAssertTrue(store.loadAll().isEmpty)
        send(["hook_event_name": "UserPromptSubmit", "session_id": "uuid-9", "prompt": "And this one?"], from: .claude)
        XCTAssertTrue(store.loadAll().isEmpty, "later questions in the same chat stay off too")

        // A chat that was filed as real work is not something to dismiss.
        send(["hook_event_name": "UserPromptSubmit", "session_id": "uuid-10", "prompt": "Fix it"], from: .claude)
        try SessionLinker(store: store).add(TaskItem(id: "", title: "Fix it"), session: "uuid-10")
        XCTAssertFalse(try SessionLinker(store: store).dismiss(session: "uuid-10"))
        XCTAssertEqual(store.loadAll().count, 1)
    }

    func testClaudeIdlePromptCoversAnInterruptedTurn() throws {
        send(["hook_event_name": "UserPromptSubmit", "session_id": "uuid-3", "prompt": "long job"], from: .claude)
        send(["hook_event_name": "Notification", "session_id": "uuid-3", "notification_type": "auth_success"], from: .claude)
        XCTAssertEqual(hooks.task(for: "uuid-3")?.status, .working)
        send(["hook_event_name": "Notification", "session_id": "uuid-3", "notification_type": "idle_prompt"], from: .claude)
        XCTAssertEqual(hooks.task(for: "uuid-3")?.status, .needsAttention)
    }

    func testClaudeSubagentEventsDoNotEndTheTurn() throws {
        send(["hook_event_name": "UserPromptSubmit", "session_id": "uuid-4", "prompt": "fan out"], from: .claude)
        send(["hook_event_name": "Stop", "session_id": "uuid-4", "agent_id": "sub-1"], from: .claude)
        XCTAssertEqual(hooks.task(for: "uuid-4")?.status, .working)
    }

    func testClaudeDesktopSessionIDComesFromTheEnvironment() throws {
        hooks.environment = ["CLAUDE_CODE_HOST_SESSION_ID": "local_abc-123", "CLAUDE_PROJECT_DIR": "/work/project"]
        send(["hook_event_name": "UserPromptSubmit", "session_id": "inner-uuid", "cwd": "/work/project/sub", "prompt": "go"], from: .claude)
        let task = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(task.agent, AgentLink(kind: .claude, session: "local_abc-123"))
        XCTAssertEqual(task.workspace, "/work/project")
        XCTAssertEqual(task.agentURL?.absoluteString, "claude://claude.ai/epitaxy/local_abc-123")
    }

    func testFilingKeepsTheAppTheSessionWasSeenIn() throws {
        send(["hook_event_name": "UserPromptSubmit", "session_id": "uuid-5", "prompt": "write the changelog"], from: .claude)
        // The default says Cursor, but the stand-in knows this chat is in Claude.
        let filed = try SessionLinker(store: store, defaultKind: .cursor).add(TaskItem(id: "", title: "Write the changelog"), session: "uuid-5")
        XCTAssertEqual(filed.agent, AgentLink(kind: .claude, session: "uuid-5"))
        // With nothing to go on, the default decides.
        let fresh = try SessionLinker(store: store, defaultKind: .claude).add(TaskItem(id: "", title: "Another"), session: "uuid-6")
        XCTAssertEqual(fresh.agent?.kind, .claude)
    }

    func testClaudeInstallerLeavesTheRestOfSettingsAlone() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash(git status)"]],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ]
        let once = HookInstaller.merged(existing: existing, kind: .claude, cliPath: "/a/taskboard")
        let twice = HookInstaller.merged(existing: once, kind: .claude, cliPath: "/b/taskboard")
        XCTAssertEqual(twice["model"] as? String, "opus")
        XCTAssertEqual((twice["permissions"] as? [String: [String]])?["allow"], ["Bash(git status)"])
        XCTAssertNil(twice["version"])
        XCTAssertTrue(HookInstaller.contains(twice, kind: .claude))

        let hooks = twice["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(hooks["Stop"]!.count, 2, "the user's own Stop hook stays, ours is added once")
        let ours = (hooks["SessionStart"]![0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(ours["type"] as? String, "command")
        XCTAssertEqual(ours["command"] as? String, "\"/b/taskboard\" hook claude 2>/dev/null || true")

        let cleaned = HookInstaller.removed(existing: twice, kind: .claude)
        XCTAssertEqual(NSDictionary(dictionary: cleaned), NSDictionary(dictionary: existing))
        // A settings file that had no hooks before has no "hooks" key afterwards.
        let bare = HookInstaller.removed(existing: HookInstaller.merged(existing: ["model": "opus"], kind: .claude, cliPath: "/a/taskboard"), kind: .claude)
        XCTAssertEqual(NSDictionary(dictionary: bare), NSDictionary(dictionary: ["model": "opus"]))
    }

    func testClaudeInstallKeepsACopyOfTheSettingsFile() throws {
        let file = home.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: file)
        try HookInstaller.install(kind: .claude, cliPath: "/a/taskboard", file: file)
        XCTAssertTrue(HookInstaller.isInstalled(kind: .claude, file: file))
        XCTAssertEqual(try String(contentsOf: HookInstaller.backupFile(for: file), encoding: .utf8), #"{"model":"opus"}"#)
        try HookInstaller.uninstall(kind: .claude, file: file)
        XCTAssertFalse(HookInstaller.isInstalled(kind: .claude, file: file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

final class APITests: XCTestCase {
    var home: URL!
    var store: TaskStore!
    var api: BoardAPI!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("taskboard-api-\(UUID().uuidString)")
        store = TaskStore(directory: home.appendingPathComponent("tasks"))
        api = BoardAPI(store: store, token: "secret", config: { .default })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// A well-formed call from this machine, with the token.
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, headers: [String: String] = [:]) -> (status: Int, json: Any?) {
        var all = ["host": "127.0.0.1:47821", "authorization": "Bearer secret"]
        all.merge(headers) { $1 }
        let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = api.respond(to: APIRequest(method: method, path: path, headers: all, body: data))
        return (response.status, response.json)
    }

    func object(_ result: (status: Int, json: Any?)) -> [String: Any] {
        result.json as? [String: Any] ?? [:]
    }

    func testWebPagesAndStrangersAreKeptOut() {
        XCTAssertEqual(call("GET", "/v1/tasks", headers: ["authorization": "Bearer wrong"]).status, 401)
        XCTAssertEqual(call("GET", "/v1/tasks", headers: ["authorization": ""]).status, 401)
        // A page in a browser names itself in Origin, even when it has the right token.
        XCTAssertEqual(call("POST", "/v1/tasks", ["title": "x"], headers: ["origin": "https://example.com"]).status, 403)
        // A domain re-pointed at this machine still shows up in Host.
        XCTAssertEqual(call("GET", "/v1/tasks", headers: ["host": "evil.example.com:47821"]).status, 403)
        XCTAssertEqual(call("GET", "/v1/tasks", headers: ["host": "localhost:47821"]).status, 200)
        // Only the health check works without a token.
        let health = api.respond(to: APIRequest(method: "GET", path: "/v1/health", headers: ["host": "127.0.0.1"]))
        XCTAssertEqual(health.status, 200)
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testCreateReadUpdateAndDelete() throws {
        let created = call("POST", "/v1/tasks", ["title": "Revamp checkout", "jira": "shop-1"])
        XCTAssertEqual(created.status, 201)
        XCTAssertEqual(object(created)["id"] as? String, "revamp-checkout")
        XCTAssertEqual(object(created)["jira"] as? String, "SHOP-1")

        let child = call("POST", "/v1/tasks", ["title": "Migrate the cart", "parent": "revamp-checkout", "pr": "https://github.example.com/team/app/pull/7"])
        XCTAssertEqual(child.status, 201)

        let list = call("GET", "/v1/tasks").json as? [[String: Any]]
        XCTAssertEqual(list?.count, 1, "subtasks are nested, not listed twice")
        XCTAssertEqual((list?.first?["subtasks"] as? [[String: Any]])?.first?["id"] as? String, "migrate-the-cart")

        let updated = call("PATCH", "/v1/tasks/migrate-the-cart", ["status": "needs-attention", "reason": "Which index?", "pr": NSNull(), "note": "Tried two approaches."])
        XCTAssertEqual(updated.status, 200)
        XCTAssertEqual(object(updated)["status"] as? String, "needs-attention")
        XCTAssertEqual(object(updated)["reason"] as? String, "Which index?")
        XCTAssertTrue(object(updated)["pr"] is NSNull, "null clears a field")
        XCTAssertEqual(store.task(id: "migrate-the-cart")?.body, "Tried two approaches.")

        XCTAssertEqual(call("DELETE", "/v1/tasks/revamp-checkout").status, 409, "a parent with subtasks is not deleted")
        XCTAssertEqual(call("DELETE", "/v1/tasks/migrate-the-cart").status, 204)
        XCTAssertEqual(call("DELETE", "/v1/tasks/revamp-checkout").status, 204)
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testBadRequestsSayWhatIsWrong() {
        func message(_ result: (status: Int, json: Any?)) -> String { object(result)["error"] as? String ?? "" }
        let long = call("POST", "/v1/tasks", ["title": String(repeating: "x", count: 51)])
        XCTAssertEqual(long.status, 400)
        XCTAssertTrue(message(long).contains("at most 50"))
        XCTAssertEqual(call("POST", "/v1/tasks", ["body": "no title"]).status, 400)
        XCTAssertEqual(call("GET", "/v1/tasks/nope").status, 404)
        _ = call("POST", "/v1/tasks", ["title": "Real"])
        XCTAssertTrue(message(call("PATCH", "/v1/tasks/real", ["status": "banana"])).contains("Unknown status"))
        XCTAssertTrue(message(call("PATCH", "/v1/tasks/real", ["colour": "red"])).contains("Unknown field"))
        XCTAssertTrue(message(call("PATCH", "/v1/tasks/real", ["parent": "missing"])).contains("No task with id"))
        XCTAssertEqual(call("PATCH", "/v1/tasks/real", ["title": 5]).status, 400)
        XCTAssertEqual(call("PUT", "/v1/tasks/real").status, 405)
        XCTAssertEqual(call("GET", "/v2/tasks").status, 404)
        XCTAssertEqual(store.task(id: "real")?.status, .idle, "a refused change changes nothing")
    }

    func testAnAgentFilesAndReportsThroughItsSession() throws {
        _ = call("POST", "/v1/tasks", ["title": "Revamp checkout"])
        // The agent files its chat as a subtask, then reports without ever learning the task's id.
        let filed = call("POST", "/v1/tasks", ["title": "Add saved cards", "parent": "revamp-checkout", "session": "chat-1", "agent": "claude"])
        XCTAssertEqual(filed.status, 201)
        let agent = object(filed)["agent"] as? [String: Any]
        XCTAssertEqual(agent?["app"] as? String, "claude")
        XCTAssertEqual(object(filed)["status"] as? String, "working")

        XCTAssertEqual(object(call("GET", "/v1/sessions/chat-1"))["id"] as? String, "add-saved-cards")
        let done = call("PATCH", "/v1/sessions/chat-1", ["status": "done", "pr": "https://github.example.com/team/app/pull/9"])
        XCTAssertEqual(object(done)["status"] as? String, "done")
        XCTAssertEqual(call("GET", "/v1/sessions/chat-unknown").status, 404)

        // A second chat carries on with the parent task.
        let attached = call("POST", "/v1/sessions/chat-2/attach", ["task": "revamp-checkout"])
        XCTAssertEqual((object(attached)["agent"] as? [String: Any])?["session"] as? String, "chat-2")
        XCTAssertEqual(call("POST", "/v1/sessions/chat-2/dismiss").status, 409, "a filed chat is not dismissed")
        XCTAssertEqual(call("POST", "/v1/sessions/chat-3/dismiss").status, 204)
    }

    func testRequestParsing() {
        func parse(_ text: String) -> LocalAPIServer.Parsed { LocalAPIServer.parse(Data(text.utf8)) }
        guard case .incomplete = parse("POST /v1/tasks HTTP/1.1\r\nHost: 127.0.0.1\r\n") else { return XCTFail("headers not finished") }
        guard case .incomplete = parse("POST /v1/tasks HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\"") else { return XCTFail("body not finished") }
        guard case .request(let request) = parse("PATCH /v1/tasks/a%20b?x=1 HTTP/1.1\r\nHost: localhost:1\r\nContent-Length: 2\r\n\r\n{}") else {
            return XCTFail("a whole request")
        }
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.path, "/v1/tasks/a%20b")
        XCTAssertEqual(request.headers["host"], "localhost:1")
        XCTAssertEqual(request.body, Data("{}".utf8))
        guard case .invalid(400, _) = parse("hello\r\n\r\n") else { return XCTFail("not HTTP") }
        guard case .invalid(413, _) = parse("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n") else { return XCTFail("too large") }
    }

    func testARealRequestOverTheNetwork() async throws {
        let api = self.api!
        let listening = expectation(description: "listening")
        var port = 0
        let server = try LocalAPIServer(port: 0, handler: { api.respond(to: $0) }, onState: { state in
            if case .listening(let bound) = state { port = bound; listening.fulfill() }
        })
        server.start()
        defer { server.stop() }
        await fulfillment(of: [listening], timeout: 5)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/tasks")!)
        request.httpMethod = "POST"
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": "Sent over HTTP"])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String, "sent-over-http")
        XCTAssertEqual(store.task(id: "sent-over-http")?.title, "Sent over HTTP")

        var unauthorised = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/tasks")!)
        unauthorised.setValue("Bearer nope", forHTTPHeaderField: "Authorization")
        let (_, refused) = try await URLSession.shared.data(for: unauthorised)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 401)
    }

    func testTokenFileIsPrivateAndStable() throws {
        let file = home.appendingPathComponent("api-token")
        let first = try APIToken.loadOrCreate(at: file)
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(try APIToken.loadOrCreate(at: file), first)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testLinksAreMarkedForTheBrowserExtension() {
        func marked(_ text: String) -> String { BrowserTabReuse.marked(URL(string: text)!).absoluteString }
        XCTAssertEqual(marked("https://github.example.com/team/app/pull/7"), "https://github.example.com/team/app/pull/7#taskboard-reuse")
        XCTAssertEqual(marked("https://example.atlassian.net/browse/DEMO-1?x=1"), "https://example.atlassian.net/browse/DEMO-1?x=1#taskboard-reuse")
        // A link with its own fragment, or one that is not for a browser, is left alone.
        XCTAssertEqual(marked("https://example.com/page#section"), "https://example.com/page#section")
        XCTAssertEqual(marked("cursor://anysphere.cursor-deeplink/agent?id=1"), "cursor://anysphere.cursor-deeplink/agent?id=1")
        XCTAssertEqual(marked("file:///tmp/task.md"), "file:///tmp/task.md")
    }
}
