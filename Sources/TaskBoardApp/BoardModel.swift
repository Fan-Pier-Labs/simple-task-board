import AppKit
import Combine
import Foundation
import TaskBoardCore

/// The app's single source of truth: tasks from disk, plus what GitHub and Jira say about them.
@MainActor
final class BoardModel: ObservableObject {
    static let columnWidth: CGFloat = 290

    @Published private(set) var config: BoardConfig
    @Published private(set) var columns: [BoardColumn] = []
    @Published private(set) var summary = BoardSummary()
    @Published private(set) var remote = RemoteState()
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    /// Problems worth showing in the header, e.g. a missing `gh`.
    @Published private(set) var syncNotes: [String] = []

    /// Whether the HTTP API is being served, for Settings to show.
    @Published private(set) var apiState: LocalAPIServer.State = .stopped

    @Published var expandedSubtasks: Set<String> = []
    @Published var expandedDetails: Set<String> = []
    /// Keeps the board open when you click elsewhere.
    @Published var pinned = false

    private var tasks: [TaskItem] = []
    private var watcher: FileWatcher?
    private var configWatcher: FileWatcher?
    private var apiServer: LocalAPIServer?
    private var apiGeneration = 0
    private var timer: Timer?
    private var remoteKeys = Set<String>()

    init(config: BoardConfig = .load()) {
        self.config = config
    }

    var tasksDirectory: URL { BoardPaths.tasksDirectory(for: config) }
    var isEmpty: Bool { tasks.isEmpty }

    // MARK: - Leaving the board for another app

    /// Hides the board. Set by the app delegate, which owns the popover.
    var closeBoard: () -> Void = {}

    /// Opens a link from a card: the board gets out of the way (unless it is pinned open)
    /// and the app that takes the link comes to the front.
    func open(_ url: URL) {
        if !pinned { closeBoard() }
        // The app that takes the link is looked up for the plain address; the browser gets the marked one.
        let destination = config.reuseBrowserTabs ? BrowserTabReuse.marked(url) : url

        // Hand focus over while this app still has it to give. Without this, an app that is
        // already running can take the link and stay behind whatever was in front.
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.first {
            handler != nil && $0.bundleURL?.standardizedFileURL.path == handler
        }
        if let running { NSApp.yieldActivation(to: running) }
        let runningID = running?.processIdentifier

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(destination, configuration: configuration) { application, _ in
            guard let processID = application?.processIdentifier ?? runningID else { return }
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: processID)?.activate(options: [.activateAllWindows])
            }
        }
    }

    func revealInFinder(_ file: URL) {
        if !pinned { closeBoard() }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // MARK: - Lifecycle

    /// Starts watching the tasks folder and polling GitHub and Jira.
    func start() {
        try? FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
        reload()
        restartWatcher()
        restartTimer()
        restartAPI()
        Task { await syncRemote() }

        // Settings changed from outside the app (`taskboard config …`) take effect straight away.
        let configWatcher = FileWatcher(directory: BoardPaths.home) { [weak self] in
            Task { @MainActor in self?.adoptConfigFromDisk() }
        }
        configWatcher.start()
        self.configWatcher = configWatcher
    }

    private func restartWatcher() {
        watcher?.stop()
        let watcher = FileWatcher(directory: tasksDirectory) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.pollSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncRemote() }
        }
    }

    /// Starts, restarts or stops the HTTP API to match the settings.
    private func restartAPI() {
        apiServer?.stop()
        apiServer = nil
        apiGeneration += 1
        let generation = apiGeneration
        guard config.apiEnabled else {
            apiState = .stopped
            return
        }
        do {
            let api = BoardAPI(
                store: TaskStore(directory: tasksDirectory),
                token: try APIToken.loadOrCreate(),
                // Read from disk per request: the API runs off the main thread, and this is always current.
                config: { BoardConfig.loadIfValid() ?? .default }
            )
            let server = try LocalAPIServer(port: config.apiPort, handler: { api.respond(to: $0) }, onState: { [weak self] state in
                Task { @MainActor in
                    // A server that was replaced reports "stopped" late; that is not news about the new one.
                    guard let self, self.apiGeneration == generation else { return }
                    self.apiState = state
                }
            })
            server.start()
            apiServer = server
        } catch {
            apiState = .failed("\(error)")
        }
    }

    // MARK: - Tasks

    func reload() {
        tasks = TaskStore(directory: tasksDirectory).loadAll()
        rebuild()

        // A task that just gained a PR, a branch or a Jira key should not wait a full minute for its status.
        if !Self.remoteKeys(of: tasks).isSubset(of: remoteKeys), watcher != nil {
            Task { await syncRemote() }
        }
    }

    /// Everything about the tasks that GitHub or Jira is asked about.
    private static func remoteKeys(of tasks: [TaskItem]) -> Set<String> {
        var keys = Set(tasks.compactMap(\.pr) + tasks.compactMap(\.jira))
        for task in tasks where task.pr == nil && task.status != .done {
            if let workspace = task.workspace, let branch = task.branch {
                keys.insert("branch \(branch) in \(workspace)")
            }
        }
        return keys
    }

    /// Supplies canned GitHub and Jira state instead of fetching it. Used for snapshots.
    func setRemoteForPreview(_ remote: RemoteState) {
        self.remote = remote
        rebuild()
    }

    private func rebuild() {
        let built = BoardBuilder.columns(tasks: tasks, config: config, remote: remote)
        if built != columns { columns = built }
        let newSummary = BoardBuilder.summary(columns: built, remote: remote)
        if newSummary != summary { summary = newSummary }
    }

    func resolvedStatus(for node: TaskNode) -> ResolvedStatus {
        StatusResolver.rollup(node, remote: remote)
    }

    func resolvedStatus(for task: TaskItem) -> ResolvedStatus {
        StatusResolver.own(task, remote: remote)
    }

    // MARK: - Config

    func updateConfig(_ mutate: (inout BoardConfig) -> Void) {
        var updated = config
        mutate(&updated)
        guard updated != config else { return }
        try? updated.save()
        apply(updated)
    }

    /// A missing or half-written file is ignored, so the board never falls back to defaults by accident.
    private func adoptConfigFromDisk() {
        guard let onDisk = BoardConfig.loadIfValid(), onDisk != config else { return }
        apply(onDisk)
    }

    private func apply(_ updated: BoardConfig) {
        let directoryChanged = BoardPaths.tasksDirectory(for: updated) != tasksDirectory
        let pollChanged = updated.pollSeconds != config.pollSeconds
        let connectionsChanged = updated.githubEnabled != config.githubEnabled
            || updated.githubHost != config.githubHost
            || updated.jiraBaseURL != config.jiraBaseURL
            || updated.jiraEmail != config.jiraEmail
        let apiChanged = updated.apiEnabled != config.apiEnabled || updated.apiPort != config.apiPort
        config = updated

        if connectionsChanged, timer != nil {
            Task { await syncRemote() }
        }
        if directoryChanged {
            try? FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
            reload()
            if watcher != nil { restartWatcher() }
        } else {
            rebuild()
        }
        if pollChanged, timer != nil { restartTimer() }
        if apiChanged || directoryChanged, timer != nil { restartAPI() }
    }

    var preferredSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let height = min(620, screen.height - 60)
        switch config.layout {
        case .board:
            let width = CGFloat(config.columns.count) * (Self.columnWidth + 10) + 10
            return CGSize(width: min(max(width, 440), screen.width - 40), height: height)
        case .list:
            return CGSize(width: 500, height: height)
        }
    }

    // MARK: - GitHub and Jira

    func syncRemote() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let snapshot = tasks
        let config = config
        let known = remote
        let directory = tasksDirectory

        let result = await Task.detached(priority: .utility) {
            await RemoteSync.run(tasks: snapshot, config: config, known: known, tasksDirectory: directory)
        }.value

        remote = result.remote
        // Pull requests found during this pass were read in it too, so they count as covered.
        remoteKeys = Self.remoteKeys(of: snapshot).union(result.remote.pullRequests.keys)
        syncNotes = result.notes
        lastSync = Date()
        isSyncing = false
        // `reload` starts another pass if tasks changed while this one was running.
        reload()
    }
}

/// One refresh pass against GitHub and Jira. Runs off the main thread.
enum RemoteSync {
    struct Result {
        var remote: RemoteState
        var notes: [String] = []
        /// True when a discovered PR link was written into a task file.
        var wroteFiles = false
    }

    static func run(tasks: [TaskItem], config: BoardConfig, known: RemoteState, tasksDirectory: URL) async -> Result {
        var result = Result(remote: RemoteState())
        var tasks = tasks

        if config.githubEnabled {
            if GitHub.cliPath == nil {
                if tasks.contains(where: { $0.pr != nil || $0.branch != nil }) {
                    result.notes.append("GitHub CLI (gh) not found, so pull request status is unavailable.")
                }
            } else {
                // Link tasks to the PR an agent opened from their branch.
                let store = TaskStore(directory: tasksDirectory)
                let candidates = tasks.indices.filter {
                    tasks[$0].pr == nil && tasks[$0].status != .done
                        && tasks[$0].workspace != nil && tasks[$0].branch != nil
                }
                let lookups = candidates.map { (workspace: tasks[$0].workspace!, branch: tasks[$0].branch!) }
                let found = await concurrentMap(lookups) {
                    GitHub.findPullRequestURL(workspace: $0.workspace, branch: $0.branch)
                }
                for (index, url) in zip(candidates, found) {
                    guard let url, var fresh = store.task(id: tasks[index].id), fresh.pr == nil else { continue }
                    fresh.pr = url
                    if (try? store.save(fresh)) != nil {
                        tasks[index].pr = url
                        result.wroteFiles = true
                    }
                }

                let urls = Array(Set(tasks.compactMap(\.pr))).sorted()
                // A merged or closed PR will not change again, so it is fetched only once.
                let settled = urls.filter { known.pullRequests[$0].map { $0.state == .merged || $0.state == .closed } ?? false }
                for url in settled { result.remote.pullRequests[url] = known.pullRequests[url] }
                let pending = urls.filter { !settled.contains($0) }
                let fetched = await concurrentMap(pending) { GitHub.fetchPullRequest(url: $0) }
                for (url, info) in zip(pending, fetched) {
                    // Keep the last known state through a failed fetch rather than blanking the icon.
                    result.remote.pullRequests[url] = info ?? known.pullRequests[url]
                }
                // Name the server when every read against it fails: that is nearly always a sign-in problem.
                var readsByHost: [String: (failed: Int, total: Int)] = [:]
                for (url, info) in zip(pending, fetched) {
                    let host = GitHub.host(ofPullRequest: url) ?? config.githubHostName
                    readsByHost[host, default: (0, 0)].total += 1
                    if info == nil { readsByHost[host, default: (0, 0)].failed += 1 }
                }
                for (host, reads) in readsByHost.sorted(by: { $0.key < $1.key }) where reads.failed == reads.total {
                    result.notes.append("Could not read pull requests on \(host). Check `gh auth status --hostname \(host)`.")
                }
            }
        }

        let jiraKeys = Array(Set(tasks.compactMap(\.jira))).sorted()
        if !jiraKeys.isEmpty, config.jiraBrowseBase != nil {
            if let client = JiraClient(config: config) {
                var firstError: String?
                for key in jiraKeys {
                    do {
                        result.remote.jiraIssues[key] = try await client.fetchIssue(key: key)
                    } catch {
                        result.remote.jiraIssues[key] = known.jiraIssues[key]
                        if firstError == nil { firstError = "\(key): \(error)" }
                    }
                }
                if let firstError { result.notes.append("Jira: \(firstError)") }
            } else {
                result.notes.append("Jira API token missing, so issue status is unavailable.")
            }
        }
        return result
    }

    /// Runs blocking work for each item, a few at a time, keeping the input order.
    static func concurrentMap<Input: Sendable, Output: Sendable>(
        _ items: [Input],
        limit: Int = 4,
        _ work: @escaping @Sendable (Input) -> Output
    ) async -> [Output] {
        var output: [Output] = []
        var start = 0
        while start < items.count {
            let chunk = Array(items[start..<min(start + limit, items.count)])
            let results = await withTaskGroup(of: (Int, Output).self) { group -> [Output] in
                for (offset, item) in chunk.enumerated() {
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            DispatchQueue.global(qos: .utility).async {
                                continuation.resume(returning: (offset, work(item)))
                            }
                        }
                    }
                }
                var collected: [(Int, Output)] = []
                for await pair in group { collected.append(pair) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            output.append(contentsOf: results)
            start += limit
        }
        return output
    }
}
