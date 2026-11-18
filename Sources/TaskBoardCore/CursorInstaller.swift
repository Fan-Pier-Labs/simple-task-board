import Foundation

/// Adds and removes this app's entries in Cursor's user-level `hooks.json`,
/// leaving every other hook in the file untouched.
public enum CursorInstaller {
    public static var hooksFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    /// A stable place for the CLI, so hooks keep working when the app moves or updates.
    public static var cliLink: URL {
        BoardPaths.home.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("taskboard")
    }

    /// Marks an entry as ours, wherever the CLI happens to live.
    static let marker = "taskboard\" hook"
    static let bareMarker = "taskboard hook"

    static func isOurs(_ entry: Any) -> Bool {
        guard let command = (entry as? [String: Any])?["command"] as? String else { return false }
        return command.hasSuffix(marker) || command.hasSuffix(bareMarker)
    }

    static func command(cliPath: String) -> String {
        "\"\(cliPath)\" hook"
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

    /// Returns the merged file contents for `cliPath` without writing anything.
    public static func merged(existing: [String: Any], cliPath: String) -> [String: Any] {
        var root = existing
        if root["version"] == nil { root["version"] = 1 }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in CursorHooks.events {
            var entries = (hooks[event] as? [Any] ?? []).filter { !isOurs($0) }
            entries.append(["command": command(cliPath: cliPath)])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return root
    }

    public static func removed(existing: [String: Any]) -> [String: Any] {
        var root = existing
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            let kept = entries.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks
        return root
    }

    public static func install(cliPath: String = cliLink.path, hooksFile: URL = hooksFile) throws {
        try write(merged(existing: try read(hooksFile), cliPath: cliPath), to: hooksFile)
    }

    public static func uninstall(hooksFile: URL = hooksFile) throws {
        guard FileManager.default.fileExists(atPath: hooksFile.path) else { return }
        try write(removed(existing: try read(hooksFile)), to: hooksFile)
    }

    public static func isInstalled(hooksFile: URL = hooksFile) -> Bool {
        guard let hooks = (try? read(hooksFile))?["hooks"] as? [String: Any] else { return false }
        return CursorHooks.events.allSatisfy { event in
            (hooks[event] as? [Any] ?? []).contains(where: isOurs)
        }
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
