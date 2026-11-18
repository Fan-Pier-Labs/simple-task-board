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
    }

    func testCursorDeepLink() {
        let task = TaskItem(id: "a", title: "A", cursorAgent: "617e7b4c-1c4b-4cf2-8a98-d881f2dc99b5")
        XCTAssertEqual(
            task.cursorURL?.absoluteString,
            "cursor://anysphere.cursor-deeplink/agent?id=617e7b4c-1c4b-4cf2-8a98-d881f2dc99b5"
        )
        XCTAssertNil(TaskItem(id: "b", title: "B").cursorURL)
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
    var hooks: CursorHooks!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("taskboard-tests-\(UUID().uuidString)")
        store = TaskStore(directory: home.appendingPathComponent("tasks"))
        hooks = CursorHooks(store: store, cliPath: "/opt/tb/taskboard")
        hooks.branchLookup = { _ in "feature/rate-limit" }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    func send(_ event: [String: Any]) -> [String: Any] {
        let payload = try! JSONSerialization.data(withJSONObject: event)
        return try! JSONSerialization.jsonObject(with: hooks.handle(payload: payload)) as! [String: Any]
    }

    func testSessionStartHandsTheAgentItsIDAndInstructions() {
        let output = send(["hook_event_name": "sessionStart", "conversation_id": "chat-1", "composer_mode": "agent"])
        XCTAssertEqual((output["env"] as? [String: String])?["TASKBOARD_SESSION"], "chat-1")
        let context = output["additional_context"] as? String ?? ""
        XCTAssertTrue(context.contains("/opt/tb/taskboard attach <task-id> --session chat-1"))
    }

    func testFirstPromptCreatesAStandInThatTheAgentRefiles() throws {
        try store.create(TaskItem(id: "", title: "Revamp auth"))
        let output = send([
            "hook_event_name": "beforeSubmitPrompt", "conversation_id": "chat-1",
            "workspace_roots": ["/work/app"],
            "prompt": "Add rate limiting to the token refresh endpoint so clients cannot hammer it",
        ])
        XCTAssertEqual(output["continue"] as? Bool, true)

        let standIn = try XCTUnwrap(store.loadAll().first { $0.cursorAgent == "chat-1" })
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
        XCTAssertEqual(task.cursorAgent, "chat-2")
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
        XCTAssertEqual(String(decoding: hooks.handle(payload: Data("nope".utf8)), as: UTF8.self), "{}")
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
        let once = CursorInstaller.merged(existing: existing, cliPath: "/a/taskboard")
        let twice = CursorInstaller.merged(existing: once, cliPath: "/b/taskboard")
        let hooks = twice["hooks"] as! [String: [[String: String]]]
        XCTAssertEqual(hooks["stop"]!.map { $0["command"]! }, ["./hooks/notify.sh", "\"/b/taskboard\" hook"])
        XCTAssertEqual(hooks["afterFileEdit"]!.count, 1)
        XCTAssertEqual(hooks["sessionStart"]!.count, 1)

        let cleaned = CursorInstaller.removed(existing: twice)["hooks"] as! [String: [[String: String]]]
        XCTAssertEqual(cleaned["stop"]!.map { $0["command"]! }, ["./hooks/notify.sh"])
        XCTAssertNil(cleaned["sessionStart"])
    }
}
