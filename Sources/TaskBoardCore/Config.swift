import Foundation

public struct ColumnConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Where a task with no explicit `column` lands, based on what is happening to it.
public struct ColumnAutomation: Codable, Equatable, Sendable {
    /// An agent is attached or has been working on it.
    public var active: String?
    /// It has an open pull request.
    public var review: String?
    /// It is done, or its pull request merged.
    public var done: String?

    public init(active: String? = nil, review: String? = nil, done: String? = nil) {
        self.active = active
        self.review = review
        self.done = done
    }
}

public enum BoardLayout: String, Codable, CaseIterable, Sendable {
    /// Columns side by side.
    case board
    /// One narrow list, grouped by column.
    case list
}

/// Everything in `config.json`. Secrets (the Jira token) live in the Keychain, never here.
public struct BoardConfig: Codable, Equatable, Sendable {
    public var columns: [ColumnConfig]
    public var automation: ColumnAutomation
    /// Folder holding the task markdown files. `nil` uses `<home>/tasks`.
    public var tasksDirectory: String?
    public var layout: BoardLayout
    /// Seconds between GitHub and Jira refreshes.
    public var pollSeconds: Int
    public var githubEnabled: Bool
    /// The GitHub server, for GitHub Enterprise: e.g. `github.example.com`. `nil` means github.com.
    public var githubHost: String?
    /// e.g. `https://example.atlassian.net`
    public var jiraBaseURL: String?
    /// Account email for Jira Cloud. Leave empty to send the token as a Bearer token (Data Center).
    public var jiraEmail: String?

    public static let `default` = BoardConfig(
        columns: [
            ColumnConfig(id: "backlog", name: "Backlog"),
            ColumnConfig(id: "in-progress", name: "In Progress"),
            ColumnConfig(id: "in-review", name: "In Review"),
            ColumnConfig(id: "done", name: "Done"),
        ],
        automation: ColumnAutomation(active: "in-progress", review: "in-review", done: "done"),
        tasksDirectory: nil,
        layout: .board,
        pollSeconds: 60,
        githubEnabled: true,
        githubHost: nil,
        jiraBaseURL: nil,
        jiraEmail: nil
    )

    public init(
        columns: [ColumnConfig],
        automation: ColumnAutomation,
        tasksDirectory: String?,
        layout: BoardLayout,
        pollSeconds: Int,
        githubEnabled: Bool,
        githubHost: String?,
        jiraBaseURL: String?,
        jiraEmail: String?
    ) {
        self.columns = columns
        self.automation = automation
        self.tasksDirectory = tasksDirectory
        self.layout = layout
        self.pollSeconds = pollSeconds
        self.githubEnabled = githubEnabled
        self.githubHost = githubHost
        self.jiraBaseURL = jiraBaseURL
        self.jiraEmail = jiraEmail
    }

    /// Missing keys fall back to the defaults, so old config files keep working.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BoardConfig.default
        let decodedColumns = try container.decodeIfPresent([ColumnConfig].self, forKey: .columns) ?? []
        columns = decodedColumns.isEmpty ? fallback.columns : decodedColumns
        automation = try container.decodeIfPresent(ColumnAutomation.self, forKey: .automation) ?? fallback.automation
        tasksDirectory = try container.decodeIfPresent(String.self, forKey: .tasksDirectory)
        layout = try container.decodeIfPresent(BoardLayout.self, forKey: .layout) ?? fallback.layout
        pollSeconds = max(15, try container.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? fallback.pollSeconds)
        githubEnabled = try container.decodeIfPresent(Bool.self, forKey: .githubEnabled) ?? fallback.githubEnabled
        githubHost = try container.decodeIfPresent(String.self, forKey: .githubHost)
        jiraBaseURL = try container.decodeIfPresent(String.self, forKey: .jiraBaseURL)
        jiraEmail = try container.decodeIfPresent(String.self, forKey: .jiraEmail)
    }

    // MARK: - Columns

    public func column(id: String?) -> ColumnConfig? {
        guard let id else { return nil }
        let key = Self.columnKey(id)
        return columns.first { Self.columnKey($0.id) == key || Self.columnKey($0.name) == key }
    }

    /// Lets `In Progress`, `in_progress` and `in-progress` all name the same column.
    public static func columnKey(_ raw: String) -> String {
        Slug.make(raw, maxLength: 60)
    }

    // MARK: - Storage

    public static func load(from url: URL = BoardPaths.configURL) -> BoardConfig {
        loadIfValid(from: url) ?? .default
    }

    /// `nil` when the file is missing or cannot be parsed.
    public static func loadIfValid(from url: URL = BoardPaths.configURL) -> BoardConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BoardConfig.self, from: data)
    }

    public func save(to url: URL = BoardPaths.configURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The host `gh` should talk to: the configured server, or github.com.
    public var githubHostName: String { GitHub.normalizeHost(githubHost) }

    public var jiraBrowseBase: URL? {
        guard let raw = jiraBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        return URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }

    public func jiraURL(for key: String) -> URL? {
        jiraBrowseBase?.appendingPathComponent("browse").appendingPathComponent(key)
    }
}

/// Where the app and the CLI keep their files. Both read the same locations.
public enum BoardPaths {
    /// `$TASKBOARD_HOME`, or `~/.taskboard`.
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["TASKBOARD_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".taskboard", isDirectory: true)
    }

    public static var configURL: URL { home.appendingPathComponent("config.json") }

    public static func tasksDirectory(for config: BoardConfig) -> URL {
        if let custom = config.tasksDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("tasks", isDirectory: true)
    }
}

public enum Slug {
    /// Lowercase, dash-separated, ASCII letters and digits only.
    public static func make(_ text: String, maxLength: Int = 40) -> String {
        var slug = ""
        var lastWasDash = true
        for scalar in text.lowercased().unicodeScalars {
            let isWordCharacter = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            if isWordCharacter {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > maxLength {
            slug = String(slug.prefix(maxLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug
    }
}
