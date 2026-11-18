import AppKit
import ServiceManagement
import SwiftUI
import TaskBoardCore

enum SettingsTab: String, CaseIterable {
    case general, columns, agents, integrations
}

struct SettingsView: View {
    @ObservedObject var model: BoardModel
    @State var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ColumnSettings(model: model)
                .tabItem { Label("Columns", systemImage: "rectangle.split.3x1") }
                .tag(SettingsTab.columns)
            AgentSettings(model: model)
                .tabItem { Label("Agents", systemImage: "person.2") }
                .tag(SettingsTab.agents)
            IntegrationSettings(model: model)
                .tabItem { Label("Integrations", systemImage: "link") }
                .tag(SettingsTab.integrations)
        }
        .frame(width: 540, height: 660)
    }
}

extension BoardModel {
    /// A binding that saves the config whenever a settings control changes it.
    func binding<Value>(_ keyPath: WritableKeyPath<BoardConfig, Value>) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { value in self.updateConfig { $0[keyPath: keyPath] = value } }
        )
    }

    /// Text fields edit `""` where the config stores `nil`.
    func textBinding(_ keyPath: WritableKeyPath<BoardConfig, String?>) -> Binding<String> {
        Binding(
            get: { self.config[keyPath: keyPath] ?? "" },
            set: { value in self.updateConfig { $0[keyPath: keyPath] = value.isEmpty ? nil : value } }
        )
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: BoardModel
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Tasks") {
                LabeledContent("Tasks folder") {
                    Text((model.tasksDirectory.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…", action: chooseFolder)
                    Button("Show in Finder") { NSWorkspace.shared.open(model.tasksDirectory) }
                    if model.config.tasksDirectory != nil {
                        Button("Use Default") { model.updateConfig { $0.tasksDirectory = nil } }
                    }
                }
                Text("Each task is one markdown file. This app only reads them; agents and the `taskboard` command write them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Board") {
                Picker("Layout", selection: model.binding(\.layout)) {
                    Text("Columns").tag(BoardLayout.board)
                    Text("List").tag(BoardLayout.list)
                }
                Picker("Check GitHub and Jira", selection: model.binding(\.pollSeconds)) {
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every 2 minutes").tag(120)
                    Text("Every 5 minutes").tag(300)
                }
                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.tasksDirectory
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            model.updateConfig { $0.tasksDirectory = url.path }
        }
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Could not change the login item. Move Task Board to the Applications folder and try again."
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Columns

private struct ColumnSettings: View {
    @ObservedObject var model: BoardModel

    private var columns: [ColumnConfig] { model.config.columns }

    var body: some View {
        Form {
            Section("Columns") {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    HStack(spacing: 6) {
                        TextField("Name", text: nameBinding(column.id), prompt: Text("Column name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button(action: { move(index, by: -1) }) { Image(systemName: "arrow.up") }
                            .disabled(index == 0)
                            .help("Move left")
                        Button(action: { move(index, by: 1) }) { Image(systemName: "arrow.down") }
                            .disabled(index == columns.count - 1)
                            .help("Move right")
                        Button(role: .destructive, action: { remove(column.id) }) { Image(systemName: "trash") }
                            .disabled(columns.count <= 1)
                            .help("Remove this column. Its tasks move to the first column.")
                    }
                    .buttonStyle(.borderless)
                }
                Button("Add Column", action: add)
            }

            Section("Move tasks on their own") {
                automationPicker("When an agent starts work", \.automation.active)
                automationPicker("When a pull request is open", \.automation.review)
                automationPicker("When it is done or merged", \.automation.done)
                Text("A task with a `column:` line in its file stays in that column.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func automationPicker(_ title: String, _ keyPath: WritableKeyPath<BoardConfig, String?>) -> some View {
        // A column that was removed reads as "Leave it where it is".
        let selection = Binding<String?>(
            get: { model.config.column(id: model.config[keyPath: keyPath])?.id },
            set: { value in model.updateConfig { $0[keyPath: keyPath] = value } }
        )
        return Picker(title, selection: selection) {
            Text("Leave it where it is").tag(String?.none)
            ForEach(columns) { column in
                Text(column.name).tag(Optional(column.id))
            }
        }
    }

    private func nameBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { columns.first { $0.id == id }?.name ?? "" },
            set: { name in
                model.updateConfig { config in
                    if let index = config.columns.firstIndex(where: { $0.id == id }) {
                        config.columns[index].name = name
                    }
                }
            }
        )
    }

    private func move(_ index: Int, by offset: Int) {
        model.updateConfig { $0.columns.swapAt(index, index + offset) }
    }

    private func remove(_ id: String) {
        model.updateConfig { $0.columns.removeAll { $0.id == id } }
    }

    private func add() {
        model.updateConfig { config in
            let id = TaskStore.uniqueID(for: "column", taken: Set(config.columns.map(\.id)))
            config.columns.append(ColumnConfig(id: id, name: "New Column"))
        }
    }
}

// MARK: - Agents

private struct AgentSettings: View {
    @ObservedObject var model: BoardModel
    /// Bumped after installing or removing hooks, so the status line is read again.
    @State private var hooksChanged = 0
    @State private var agentMessage: String?
    @State private var portText = ""
    @State private var copiedExample = false

    var body: some View {
        Form {
            Section("Coding agent") {
                Picker("Agents run in", selection: model.binding(\.agent)) {
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("\(agent.displayName) hooks") {
                    HStack {
                        Text(hooksInstalled ? "Installed" : "Not installed").foregroundStyle(.secondary)
                        Button(hooksInstalled ? "Reinstall" : "Install", action: installHooks)
                        if hooksInstalled { Button("Remove", action: removeHooks) }
                    }
                }
                Text(hooksCaption).font(.caption).foregroundStyle(.secondary)
                if let agentMessage {
                    Text(agentMessage).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("API") {
                Toggle("Let agents and scripts update the board over HTTP", isOn: model.binding(\.apiEnabled))
                TextField("Port", text: $portText, prompt: Text(String(BoardConfig.default.apiPort)))
                    .onSubmit(applyPort)
                LabeledContent("Status") {
                    Text(apiStatus).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(copiedExample ? "Copied" : "Copy Example Command", action: copyExample)
                    .disabled(!model.config.apiEnabled)
                Text("Answers only on this Mac, and only to callers that send the token kept in ~/.taskboard/api-token. The `taskboard` command does the same job without it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(model.config.apiPort) }
    }

    /// The CLI ships next to the app binary, inside the bundle.
    private var bundledCLI: URL? {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let url = directory.appendingPathComponent("taskboard")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private var apiStatus: String {
        switch model.apiState {
        case .starting: return "Starting…"
        case .listening(let port): return "Listening on http://127.0.0.1:\(port)"
        case .failed(let reason): return "Not running. \(reason)"
        case .stopped: return "Off"
        }
    }

    private func applyPort() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else {
            portText = String(model.config.apiPort)
            return
        }
        model.updateConfig { $0.apiPort = port }
    }

    private func copyExample() {
        let example = "curl -s -H \"Authorization: Bearer $(cat ~/.taskboard/api-token)\" \(model.config.apiBaseURL)/v1/tasks"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(example, forType: .string)
        copiedExample = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedExample = false }
    }

    private var agent: AgentKind { model.config.agent }

    private var hooksInstalled: Bool {
        _ = hooksChanged
        return HookInstaller.isInstalled(kind: agent)
    }

    private var hooksCaption: String {
        let behaviour = "Each new agent chat then shows up here on its own, files itself under the right task, and flips between working and waiting as it runs."
        switch agent {
        case .cursor:
            return "Adds four entries to ~/.cursor/hooks.json. " + behaviour
        case .claude:
            return "Adds six entries to ~/.claude/settings.json, keeping a copy of the file as it was. "
                + behaviour + " Claude asks before it first runs the taskboard command; choose to always allow it."
        }
    }

    private func installHooks() {
        do {
            if let bundledCLI { try HookInstaller.linkCLI(from: bundledCLI) }
            guard FileManager.default.isExecutableFile(atPath: HookInstaller.cliLink.path) else {
                agentMessage = "The taskboard command is missing from this build, so the hooks would have nothing to run."
                return
            }
            try HookInstaller.install(kind: agent)
            agentMessage = nil
        } catch {
            agentMessage = "\(error)"
        }
        hooksChanged += 1
    }

    private func removeHooks() {
        do {
            try HookInstaller.uninstall(kind: agent)
            agentMessage = nil
        } catch {
            agentMessage = "\(error)"
        }
        hooksChanged += 1
    }
}

// MARK: - Integrations

private struct IntegrationSettings: View {
    @ObservedObject var model: BoardModel
    @State private var githubMessage: String?
    @State private var testingGitHub = false
    @State private var jiraToken = ""
    @State private var hasJiraToken = JiraCredentials.hasStoredToken
    @State private var jiraMessage: String?
    @State private var testingJira = false

    var body: some View {
        Form {
            Section("GitHub") {
                Toggle("Show pull request and CI status", isOn: model.binding(\.githubEnabled))
                TextField("Server", text: model.textBinding(\.githubHost), prompt: Text("github.com"))
                LabeledContent("GitHub CLI") {
                    Text(GitHub.cliPath ?? "Not found. Install gh first.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Test Connection", action: testGitHub).disabled(testingGitHub)
                    if testingGitHub { ProgressView().controlSize(.small) }
                }
                if let githubMessage {
                    Text(githubMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("For GitHub Enterprise, enter your server's address, such as github.example.com. Sign-in is handled by the GitHub CLI.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Browser") {
                Toggle("Switch to a tab that is already open", isOn: model.binding(\.reuseBrowserTabs))
                if let extensionFolder {
                    Button("Show Extension Folder") { NSWorkspace.shared.activateFileViewerSelecting([extensionFolder]) }
                }
                Text("Needs the Task Board extension in your browser. In Chrome, open chrome://extensions, turn on Developer mode, click Load unpacked and choose the extension folder. Without it, links open in a new tab as usual.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Jira (read-only)") {
                TextField("Site", text: model.textBinding(\.jiraBaseURL), prompt: Text("https://your-team.atlassian.net"))
                TextField("Email", text: model.textBinding(\.jiraEmail), prompt: Text("Leave empty for a Data Center token"))
                SecureField("API token", text: $jiraToken, prompt: Text(hasJiraToken ? "Saved in your Keychain" : "Paste a token"))
                HStack {
                    Button("Save Token", action: saveToken).disabled(jiraToken.isEmpty)
                    if hasJiraToken { Button("Forget Token", action: forgetToken) }
                    Button("Test Connection", action: testJira).disabled(testingJira || !hasJiraToken)
                    if testingJira { ProgressView().controlSize(.small) }
                }
                if let jiraMessage {
                    Text(jiraMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The browser extension ships inside the app bundle.
    private var extensionFolder: URL? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("extension"),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path)
        else { return nil }
        return folder
    }

    private func testGitHub() {
        let host = model.config.githubHostName
        testingGitHub = true
        githubMessage = nil
        Task {
            let connection = await Task.detached { GitHub.currentUser(host: host) }.value
            switch connection {
            case .connected(let login):
                githubMessage = "Connected to \(host) as \(login)."
            case .cliMissing:
                githubMessage = "The GitHub CLI (gh) is not installed."
            case .failed(let detail):
                githubMessage = "Could not connect to \(host): \(detail)\nTo sign in, run: \(GitHub.signInCommand(host: host))"
            }
            testingGitHub = false
        }
    }

    private func saveToken() {
        if JiraCredentials.setToken(jiraToken) {
            jiraToken = ""
            jiraMessage = "Token saved to your Keychain."
        } else {
            jiraMessage = "Could not save the token to your Keychain."
        }
        hasJiraToken = JiraCredentials.hasStoredToken
        Task { await model.syncRemote() }
    }

    private func forgetToken() {
        JiraCredentials.setToken(nil)
        hasJiraToken = JiraCredentials.hasStoredToken
        jiraMessage = "Token removed."
    }

    private func testJira() {
        guard let client = JiraClient(config: model.config) else {
            jiraMessage = "Enter the site address first."
            return
        }
        testingJira = true
        jiraMessage = nil
        Task {
            do {
                let name = try await client.currentUser()
                jiraMessage = "Connected as \(name)."
            } catch {
                jiraMessage = "\(error)"
            }
            testingJira = false
        }
    }
}
