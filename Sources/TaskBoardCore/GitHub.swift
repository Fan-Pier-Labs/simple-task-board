import Foundation

public struct PullRequestInfo: Equatable, Sendable, Codable {
    public enum State: String, Sendable, Codable {
        case open, draft, merged, closed
    }

    public enum Checks: String, Sendable, Codable {
        /// The PR has no checks.
        case none
        case pending, passing, failing
    }

    public var url: String
    public var number: Int?
    public var title: String?
    public var state: State
    public var checks: Checks
    public var failingChecks: [String]
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or `nil`.
    public var reviewDecision: String?

    public init(
        url: String,
        number: Int? = nil,
        title: String? = nil,
        state: State,
        checks: Checks = .none,
        failingChecks: [String] = [],
        reviewDecision: String? = nil
    ) {
        self.url = url
        self.number = number
        self.title = title
        self.state = state
        self.checks = checks
        self.failingChecks = failingChecks
        self.reviewDecision = reviewDecision
    }

    /// One line for tooltips and the detail view.
    public var summary: String {
        var parts: [String] = []
        switch state {
        case .open: parts.append("Open")
        case .draft: parts.append("Draft")
        case .merged: parts.append("Merged")
        case .closed: parts.append("Closed")
        }
        if state == .open || state == .draft {
            switch checks {
            case .none: break
            case .pending: parts.append("checks running")
            case .passing: parts.append("checks passing")
            case .failing: parts.append("checks failing")
            }
            switch reviewDecision {
            case "APPROVED": parts.append("approved")
            case "CHANGES_REQUESTED": parts.append("changes requested")
            default: break
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Read-only GitHub access through the `gh` CLI, so the app never handles a GitHub token itself.
///
/// GitHub Enterprise needs no special handling when reading a pull request: `gh` takes the server
/// from the pull request's URL, or from the workspace's git remote, and uses whichever account it
/// is signed in to there (`gh auth login --hostname <server>`).
public enum GitHub {
    public static var cliPath: String? { Shell.find("gh") }

    public static let defaultHost = "github.com"

    /// Accepts `github.example.com`, `https://github.example.com/some/path`, or nothing (github.com).
    public static func normalizeHost(_ raw: String?) -> String {
        var text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        return text.isEmpty ? defaultHost : text
    }

    public static func host(ofPullRequest url: String) -> String? {
        URL(string: url)?.host?.lowercased()
    }

    public static func signInCommand(host: String) -> String {
        "gh auth login --hostname \(host)"
    }

    public enum Connection: Equatable {
        case connected(login: String)
        case cliMissing
        /// `detail` is what `gh` said, e.g. that it has no account for that server.
        case failed(detail: String)
    }

    /// Asks the server who `gh` is signed in as. A real round trip, so it also proves the server is reachable.
    public static func currentUser(host: String) -> Connection {
        guard let gh = cliPath,
              let result = Shell.run(gh, ["api", "--hostname", host, "user", "--jq", ".login"])
        else { return .cliMissing }
        let login = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.succeeded, !login.isEmpty { return .connected(login: login) }
        let firstLine = result.stderr.split(separator: "\n").first.map(String.init) ?? "gh exited with status \(result.status)"
        return .failed(detail: firstLine)
    }

    static let viewFields = "number,title,url,state,isDraft,reviewDecision,statusCheckRollup"

    public static func fetchPullRequest(url: String) -> PullRequestInfo? {
        guard let gh = cliPath,
              let result = Shell.run(gh, ["pr", "view", url, "--json", viewFields]),
              result.succeeded
        else { return nil }
        return parsePullRequest(json: Data(result.stdout.utf8), url: url)
    }

    /// The pull request for a branch of the repository checked out at `workspace`, if there is one.
    public static func findPullRequestURL(workspace: String, branch: String) -> String? {
        guard let gh = cliPath,
              let result = Shell.run(
                gh, ["pr", "list", "--head", branch, "--state", "all", "--limit", "10", "--json", "url,state"],
                cwd: workspace
              ),
              result.succeeded,
              let list = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
        else { return nil }
        let open = list.first { ($0["state"] as? String) == "OPEN" }
        return (open ?? list.first)?["url"] as? String
    }

    /// Parses the output of `gh pr view --json …`.
    public static func parsePullRequest(json: Data, url: String) -> PullRequestInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let rawState = object["state"] as? String
        else { return nil }

        let state: PullRequestInfo.State
        switch rawState.uppercased() {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: state = (object["isDraft"] as? Bool) == true ? .draft : .open
        }

        var failing: [String] = []
        var pending = 0
        var total = 0
        for check in object["statusCheckRollup"] as? [[String: Any]] ?? [] {
            total += 1
            let name = (check["name"] as? String) ?? (check["context"] as? String) ?? "check"
            // Check runs report `status` + `conclusion`; commit statuses report a single `state`.
            let outcome = ((check["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (check["state"] as? String)
                ?? (check["status"] as? String)
                ?? "").uppercased()
            switch outcome {
            case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE":
                failing.append(name)
            case "SUCCESS", "NEUTRAL", "SKIPPED", "COMPLETED":
                break
            default:
                pending += 1
            }
        }

        let checks: PullRequestInfo.Checks
        if total == 0 { checks = .none }
        else if !failing.isEmpty { checks = .failing }
        else if pending > 0 { checks = .pending }
        else { checks = .passing }

        let review = (object["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PullRequestInfo(
            url: (object["url"] as? String) ?? url,
            number: object["number"] as? Int,
            title: object["title"] as? String,
            state: state,
            checks: checks,
            failingChecks: failing,
            reviewDecision: review
        )
    }
}
