import Foundation

/// One line of `taskboard doctor`.
public struct DoctorCheck: Equatable, Sendable {
    public enum Outcome: String, Sendable {
        case pass
        /// Not broken, but not proven either: usually something that has not been set up or tried yet.
        case warning
        case failure
    }

    public var area: String
    public var outcome: Outcome
    public var message: String
    /// What to do about a warning or failure.
    public var fix: String?

    public init(_ area: String, _ outcome: Outcome, _ message: String, fix: String? = nil) {
        self.area = area
        self.outcome = outcome
        self.message = message
        self.fix = fix
    }
}

/// Checks each connection for real: the task files, the agent app's hooks, GitHub through `gh`, and Jira.
/// Everything it does is read-only.
public struct Doctor: Sendable {
    public let config: BoardConfig
    public let store: TaskStore
    /// `nil` means the usual file for the agent app chosen in Settings.
    public var hooksFile: URL?
    public var cliLink = HookInstaller.cliLink

    public init(config: BoardConfig, store: TaskStore) {
        self.config = config
        self.store = store
    }

    public func run() async -> [DoctorCheck] {
        let tasks = store.loadAll()
        return taskChecks(tasks) + agentChecks(tasks) + githubChecks(tasks) + (await jiraChecks(tasks))
    }

    private func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Tasks

    func taskChecks(_ tasks: [TaskItem]) -> [DoctorCheck] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: store.directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return [DoctorCheck(
                "Tasks", .failure, "The tasks folder \(display(store.directory)) does not exist.",
                fix: "Launch Task Board once, or choose a folder in Settings."
            )]
        }
        return [DoctorCheck("Tasks", .pass, "\(display(store.directory)) holds \(tasks.count) task(s).")]
    }

    // MARK: - Cursor or Claude

    func agentChecks(_ tasks: [TaskItem]) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let kind = config.agent
        let area = kind.displayName
        let file = hooksFile ?? HookInstaller.hooksFile(for: kind)
        let installCommand = "taskboard install-\(kind.rawValue)-hooks"

        if FileManager.default.isExecutableFile(atPath: cliLink.path) {
            checks.append(DoctorCheck(area, .pass, "The command is at \(display(cliLink))."))
        } else {
            checks.append(DoctorCheck(
                area, .failure, "\(display(cliLink)) is missing, so the hooks have nothing to run.",
                fix: "Launch Task Board once, or run `\(installCommand)`."
            ))
        }

        if HookInstaller.isInstalled(kind: kind, file: file) {
            checks.append(DoctorCheck(area, .pass, "The hooks are installed in \(display(file))."))
        } else {
            checks.append(DoctorCheck(
                area, .failure, "The hooks are not installed in \(display(file)).",
                fix: "Run `\(installCommand)`."
            ))
        }

        let linked = tasks.filter { $0.agent?.kind == kind }.count
        if linked > 0 {
            checks.append(DoctorCheck(area, .pass, "\(linked) task(s) are linked to a \(area) chat, so hooks have fired."))
        } else {
            checks.append(DoctorCheck(
                area, .warning, "No \(area) chat has reported yet, so the hooks are unproven.",
                fix: "Start a new agent chat in \(area), send it a prompt, then run this again."
            ))
        }
        return checks
    }

    // MARK: - GitHub

    func githubChecks(_ tasks: [TaskItem]) -> [DoctorCheck] {
        let area = "GitHub"
        guard config.githubEnabled else {
            return [DoctorCheck(area, .warning, "Pull request status is switched off in Settings.")]
        }
        guard let gh = GitHub.cliPath else {
            return [DoctorCheck(area, .failure, "The GitHub CLI (gh) is not installed.", fix: "Install it from https://cli.github.com.")]
        }
        var checks = [DoctorCheck(area, .pass, "The GitHub CLI is at \(gh).")]

        // The configured server, plus any other server a task's pull request lives on.
        var hosts = [config.githubHostName]
        for host in tasks.compactMap(\.pr).compactMap(GitHub.host(ofPullRequest:)).sorted() where !hosts.contains(host) {
            hosts.append(host)
        }
        for host in hosts {
            switch GitHub.currentUser(host: host) {
            case .connected(let login):
                checks.append(DoctorCheck(area, .pass, "Signed in to \(host) as \(login)."))
            case .cliMissing:
                checks.append(DoctorCheck(area, .failure, "Could not run gh."))
            case .failed(let detail):
                checks.append(DoctorCheck(
                    area, .failure, "Cannot use \(host): \(detail)",
                    fix: "Check the address and your VPN. To sign in, run `\(GitHub.signInCommand(host: host))`."
                ))
            }
        }

        let sample = Array(tasks.filter { $0.status != .done }.compactMap(\.pr).prefix(3))
        if sample.isEmpty {
            checks.append(DoctorCheck(
                area, .warning, "No open task has a pull request, so reading one is unproven.",
                fix: "Link one: `taskboard add \"PR check\" --pr <pull request url>`, then run this again."
            ))
        }
        for url in sample {
            if let info = GitHub.fetchPullRequest(url: url) {
                checks.append(DoctorCheck(area, .pass, "Read \(url): \(info.summary)."))
            } else {
                checks.append(DoctorCheck(
                    area, .failure, "Could not read \(url).",
                    fix: "Check the link, and that `gh pr view \(url)` works in a terminal."
                ))
            }
        }
        return checks
    }

    // MARK: - Jira

    func jiraChecks(_ tasks: [TaskItem]) async -> [DoctorCheck] {
        let area = "Jira"
        guard let base = config.jiraBrowseBase else {
            return [DoctorCheck(
                area, .warning, "Jira is not set up.",
                fix: "Run `taskboard config jira-site https://your-team.atlassian.net` and `taskboard config jira-email <you>`."
            )]
        }
        guard let client = JiraClient(config: config) else {
            return [DoctorCheck(
                area, .failure, "The Jira site is set, but there is no API token.",
                fix: "Open Settings → Integrations → Jira in Task Board, paste a token and click Save Token."
            )]
        }

        var checks: [DoctorCheck] = []
        let host = base.host ?? base.absoluteString
        do {
            checks.append(DoctorCheck(area, .pass, "Connected to \(host) as \(try await client.currentUser())."))
        } catch {
            let hint = config.jiraEmail?.isEmpty == false
                ? "Check the site address, the email, and that the token is still valid."
                : "No email is set, so the token is sent as a Data Center token. For Jira Cloud, set the email too."
            return [DoctorCheck(area, .failure, "Could not connect to \(host): \(error)", fix: hint)]
        }

        guard let key = tasks.compactMap(\.jira).first else {
            checks.append(DoctorCheck(
                area, .warning, "No task is linked to a Jira issue, so reading one is unproven.",
                fix: "Link one: `taskboard add \"Jira check\" --jira <KEY>`, then run this again."
            ))
            return checks
        }
        do {
            let issue = try await client.fetchIssue(key: key)
            checks.append(DoctorCheck(area, .pass, "Read \(issue.key): \(issue.statusName)."))
        } catch {
            checks.append(DoctorCheck(area, .failure, "Could not read \(key): \(error)"))
        }
        return checks
    }
}
