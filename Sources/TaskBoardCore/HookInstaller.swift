import Foundation

/// Adds and removes this app's hook entries in Cursor's `hooks.json` or Claude's `settings.json`,
/// leaving everything else in those files untouched.
public enum HookInstaller {
    public static func hooksFile(for kind: AgentKind) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch kind {
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        }
    }

    /// A stable place for the CLI, so hooks keep working when the app moves or updates.
    public static var cliLink: URL {
        BoardPaths.home.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("taskboard")
    }

    public static func events(for kind: AgentKind) -> [String] {
        switch kind {
        case .cursor: return ["sessionStart", "beforeSubmitPrompt", "stop", "sessionEnd"]
        case .claude: return ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "PostToolUse", "SessionEnd"]
        }
    }

    static func command(cliPath: String, kind: AgentKind) -> String {
        let command = "\"\(cliPath)\" hook \(kind.rawValue)"
        switch kind {
        case .cursor:
            return command
        case .claude:
            // Claude runs hooks through a shell and shows their errors in the chat. If the app has
            // been deleted, the hook should do nothing rather than complain in every session.
            return command + " 2>/dev/null || true"
        }
    }

    /// Recognises our command wherever the CLI happens to live.
    static func isOurs(command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("taskboard\" hook") || command.contains("taskboard hook")
    }

    public enum InstallError: Error, CustomStringConvertible {
        case unreadable(URL)

        public var description: String {
            switch self {
            case .unreadable(let url):
                return "\(url.path) exists but is not valid JSON. Fix or remove it, then try again."
            }
        }
    }

    // MARK: - Merging

    /// Returns the file contents with our hooks added, without writing anything.
    public static func merged(existing: [String: Any], kind: AgentKind, cliPath: String) -> [String: Any] {
        var root = removed(existing: existing, kind: kind)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = command(cliPath: cliPath, kind: kind)
        for event in events(for: kind) {
            var entries = hooks[event] as? [Any] ?? []
            switch kind {
            case .cursor:
                entries.append(["command": command])
            case .claude:
                // One matcher group holding one command hook. No matcher means every occurrence.
                entries.append(["hooks": [["type": "command", "command": command, "timeout": 10] as [String: Any]]])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        if kind == .cursor, root["version"] == nil { root["version"] = 1 }
        return root
    }

    /// Returns the file contents with our hooks taken out, and nothing else changed.
    public static func removed(existing: [String: Any], kind: AgentKind) -> [String: Any] {
        var root = existing
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            let kept: [Any]
            switch kind {
            case .cursor:
                kept = entries.filter { !isOurs(command: ($0 as? [String: Any])?["command"] as? String) }
            case .claude:
                kept = entries.compactMap { entry -> Any? in
                    guard var group = entry as? [String: Any], let inner = group["hooks"] as? [Any] else { return entry }
                    let others = inner.filter { !isOurs(command: ($0 as? [String: Any])?["command"] as? String) }
                    if others.count == inner.count { return entry }
                    if others.isEmpty { return nil }
                    group["hooks"] = others
                    return group
                }
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        // Claude's settings file had no "hooks" key before us if we leave none behind.
        root["hooks"] = hooks.isEmpty && kind == .claude ? nil : hooks
        return root
    }

    static func contains(_ root: [String: Any], kind: AgentKind) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        return events(for: kind).allSatisfy { event in
            (hooks[event] as? [Any] ?? []).contains { entry in
                guard let entry = entry as? [String: Any] else { return false }
                switch kind {
                case .cursor:
                    return isOurs(command: entry["command"] as? String)
                case .claude:
                    return (entry["hooks"] as? [Any] ?? []).contains {
                        isOurs(command: ($0 as? [String: Any])?["command"] as? String)
                    }
                }
            }
        }
    }

    // MARK: - Files

    private static func read(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw InstallError.unreadable(file) }
        return object
    }

    private static func write(_ root: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    /// Where the file as it was before our first change is kept.
    public static func backupFile(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".before-taskboard")
    }

    public static func install(kind: AgentKind, cliPath: String = cliLink.path, file: URL? = nil) throws {
        let file = file ?? hooksFile(for: kind)
        let existing = try read(file)
        // Claude's settings file holds much more than hooks, so keep a copy of it as it was.
        let backup = backupFile(for: file)
        if kind == .claude, FileManager.default.fileExists(atPath: file.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: file, to: backup)
        }
        try write(merged(existing: existing, kind: kind, cliPath: cliPath), to: file)
    }

    public static func uninstall(kind: AgentKind, file: URL? = nil) throws {
        let file = file ?? hooksFile(for: kind)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let cleaned = removed(existing: try read(file), kind: kind)
        // A Cursor hooks file that held nothing but our entries is removed rather than left empty.
        let hooksLeft = (cleaned["hooks"] as? [String: Any])?.isEmpty == false
        if kind == .cursor, !hooksLeft, Set(cleaned.keys).isSubset(of: ["hooks", "version"]) {
            try FileManager.default.removeItem(at: file)
        } else {
            try write(cleaned, to: file)
        }
    }

    public static func isInstalled(kind: AgentKind, file: URL? = nil) -> Bool {
        guard let root = try? read(file ?? hooksFile(for: kind)) else { return false }
        return contains(root, kind: kind)
    }

    /// Points `~/.taskboard/bin/taskboard` at the given CLI binary.
    public static func linkCLI(from binary: URL, to link: URL = cliLink) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current = try? fileManager.destinationOfSymbolicLink(atPath: link.path), current == binary.path {
            return
        }
        // `fileExists` follows links, so a dangling link has to be removed by attempting it.
        try? fileManager.removeItem(at: link)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: binary)
    }
}
