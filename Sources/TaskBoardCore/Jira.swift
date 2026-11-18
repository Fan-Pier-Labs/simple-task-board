import Foundation
import Security

public struct JiraIssue: Equatable, Sendable, Codable {
    public enum Category: String, Sendable, Codable {
        case todo, inProgress, done, unknown
    }

    public var key: String
    public var summary: String
    /// The workflow status as named in Jira, e.g. "In Review".
    public var statusName: String
    public var category: Category

    public init(key: String, summary: String, statusName: String, category: Category) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.category = category
    }
}

public enum JiraError: Error, CustomStringConvertible {
    case notConfigured
    case http(Int)
    case malformedResponse

    public var description: String {
        switch self {
        case .notConfigured: return "Jira is not configured. Add the site URL and an API token in Settings."
        case .http(401), .http(403): return "Jira rejected the credentials."
        case .http(404): return "Jira issue not found, or you do not have access to it."
        case .http(let code): return "Jira returned HTTP \(code)."
        case .malformedResponse: return "Jira sent a response this app could not read."
        }
    }
}

/// Read-only Jira client. It only ever issues GET requests.
public struct JiraClient: Sendable {
    public let baseURL: URL
    public let email: String?
    public let token: String

    public init(baseURL: URL, email: String?, token: String) {
        self.baseURL = baseURL
        self.email = email
        self.token = token
    }

    /// Builds a client from the config plus the stored token, or `nil` if either is missing.
    public init?(config: BoardConfig) {
        guard let baseURL = config.jiraBrowseBase, let token = JiraCredentials.token(), !token.isEmpty else {
            return nil
        }
        self.init(baseURL: baseURL, email: config.jiraEmail, token: token)
    }

    func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty {
            // Jira Cloud: basic auth with the account email and an API token.
            let basic = Data("\(email):\(token)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        } else {
            // Jira Data Center: a personal access token.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JiraError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw JiraError.http(http.statusCode) }
        return data
    }

    public func fetchIssue(key: String) async throws -> JiraIssue {
        // API v2 is served by both Jira Cloud and Data Center.
        let request = request(
            path: "rest/api/2/issue/\(key)",
            query: [URLQueryItem(name: "fields", value: "summary,status")]
        )
        guard let issue = Self.parseIssue(json: try await get(request)) else { throw JiraError.malformedResponse }
        return issue
    }

    /// The display name of the authenticated account; used by "Test connection".
    public func currentUser() async throws -> String {
        let data = try await get(request(path: "rest/api/2/myself"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraError.malformedResponse
        }
        return (object["displayName"] as? String) ?? (object["name"] as? String) ?? "unknown user"
    }

    public static func parseIssue(json: Data) -> JiraIssue? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let key = object["key"] as? String,
              let fields = object["fields"] as? [String: Any]
        else { return nil }
        let status = fields["status"] as? [String: Any]
        let categoryKey = ((status?["statusCategory"] as? [String: Any])?["key"] as? String) ?? ""
        let category: JiraIssue.Category
        switch categoryKey {
        case "new": category = .todo
        case "indeterminate": category = .inProgress
        case "done": category = .done
        default: category = .unknown
        }
        return JiraIssue(
            key: key,
            summary: (fields["summary"] as? String) ?? "",
            statusName: (status?["name"] as? String) ?? "Unknown",
            category: category
        )
    }
}

/// The Jira API token, kept in the login Keychain. `JIRA_API_TOKEN` overrides it.
public enum JiraCredentials {
    static let service = "simple-task-board"
    static let account = "jira-api-token"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func token() -> String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment["JIRA_API_TOKEN"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the token, or removes it when given `nil` or an empty string.
    @discardableResult
    public static func setToken(_ token: String?) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static var hasStoredToken: Bool {
        var lookup = query
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(lookup as CFDictionary, nil) == errSecSuccess
    }
}
