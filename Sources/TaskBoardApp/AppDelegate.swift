import AppKit
import Combine
import SwiftUI
import TaskBoardCore

/// Owns the menu bar icon, the board popover under it, and the settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BoardModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var debugSnapshotSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        linkBundledCLI()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Task Board")
        }
        statusItem = item

        let board = BoardView(model: model, actions: BoardActions(openSettings: { [weak self] in self?.showSettings() }))
        let hosting = NSHostingController(rootView: board)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient

        model.$summary
            .sink { [weak self] summary in self?.updateStatusItem(summary) }
            .store(in: &subscriptions)
        model.$pinned
            .sink { [weak self] pinned in self?.popover.behavior = pinned ? .applicationDefined : .transient }
            .store(in: &subscriptions)

        model.start()

        installDebugSnapshotHandler()

        // `--show-board` opens the board at launch, which is handy when developing.
        if CommandLine.arguments.contains("--show-board") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.togglePopover() }
        }
    }

    /// Keeps `~/.taskboard/bin/taskboard` pointing at the CLI inside this copy of the app,
    /// so installed hooks keep working after the app moves or updates.
    private func linkBundledCLI() {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
        let cli = directory.appendingPathComponent("taskboard")
        if FileManager.default.isExecutableFile(atPath: cli.path) {
            try? HookInstaller.linkCLI(from: cli)
        }
    }

    /// Development aid: with `TASKBOARD_DEBUG_SNAPSHOT=<file.png>` set, sending the app SIGUSR1
    /// writes a picture of the open board to that file. It draws the app's own view, so it needs
    /// no screen recording permission.
    private func installDebugSnapshotHandler() {
        guard let path = ProcessInfo.processInfo.environment["TASKBOARD_DEBUG_SNAPSHOT"], !path.isEmpty else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let view = self?.popover.contentViewController?.view,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        source.resume()
        debugSnapshotSignal = source
    }

    // MARK: - Menu bar icon

    private func updateStatusItem(_ summary: BoardSummary) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Task Board")

        // The icon summarises every task: how many agents are busy, and how many need you.
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        func append(symbol: String, count: Int, color: NSColor) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(.init(paletteColors: [color]))
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let attachment = NSTextAttachment()
                attachment.image = image
                title.append(NSAttributedString(string: " "))
                title.append(NSAttributedString(attachment: attachment))
            }
            title.append(NSAttributedString(string: " \(count)", attributes: [.font: font, .foregroundColor: color]))
        }
        if summary.working > 0 {
            append(symbol: "arrow.triangle.2.circlepath", count: summary.working, color: .labelColor)
        }
        if summary.needsAttention > 0 {
            append(symbol: "exclamationmark.circle.fill", count: summary.needsAttention, color: .systemOrange)
        }
        button.attributedTitle = title

        var tooltip = "Task Board"
        if summary.working > 0 { tooltip += " · \(summary.working) working" }
        if summary.needsAttention > 0 { tooltip += " · \(summary.needsAttention) need you" }
        button.toolTip = tooltip
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.reload()
        Task { await model.syncRemote() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Task Board", action: #selector(openBoardFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Tasks Folder", action: #selector(openTasksFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Task Board", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Attaching the menu only for this click keeps left-click free for the board.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openBoardFromMenu() {
        if !popover.isShown { togglePopover() }
    }

    @objc private func openTasksFolder() {
        NSWorkspace.shared.open(model.tasksDirectory)
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    // MARK: - Settings

    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Task Board Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
