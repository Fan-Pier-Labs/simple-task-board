import Foundation

public struct ShellResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

/// Runs command-line tools (`gh`, `git`) without going through a shell.
public enum Shell {
    /// A GUI app starts with a bare PATH, so tools installed by Homebrew are looked up explicitly.
    static let extraSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    public static func find(_ tool: String) -> String? {
        let fromEnvironment = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = fromEnvironment + extraSearchPaths + ["\(home)/.local/bin", "\(home)/bin"]
        for directory in candidates {
            let path = (directory as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Returns `nil` if the tool could not be started. Kills it after `timeout` seconds.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 20
    ) -> ShellResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        var environment = ProcessInfo.processInfo.environment
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (path + extraSearchPaths.filter { !path.contains($0) }).joined(separator: ":")
        // Never let a tool stop to ask a question nobody can answer.
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Drain both pipes at once so a chatty stderr cannot block the tool.
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self)
        )
    }
}

public enum Git {
    static let defaultBranches: Set<String> = ["main", "master", "develop", "trunk", "HEAD"]

    /// The checked-out branch of a workspace, or `nil` on a default branch or outside a repository.
    public static func featureBranch(in workspace: String) -> String? {
        guard let git = Shell.find("git"),
              let result = Shell.run(git, ["-C", workspace, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 5),
              result.succeeded
        else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || defaultBranches.contains(branch) ? nil : branch
    }
}
