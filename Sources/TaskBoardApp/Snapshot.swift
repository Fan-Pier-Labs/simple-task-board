import AppKit
import SwiftUI
import TaskBoardCore

/// Renders the board or the settings window to a PNG without showing anything on screen.
/// Used to check the UI from the command line and to produce the README screenshots.
///
///     TaskBoardApp --snapshot board.png [--remote state.json] [--expand id,id]
///                  [--details id,id] [--layout board|list] [--dark]
///     TaskBoardApp --snapshot settings.png --settings general|columns|integrations
@MainActor
enum Snapshot {
    static func run(arguments: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        func ids(_ name: String) -> Set<String> {
            Set((value(name) ?? "").split(separator: ",").map(String.init))
        }
        guard let output = value("--snapshot") else { return 2 }

        var config = BoardConfig.load()
        if let layout = value("--layout").flatMap(BoardLayout.init(rawValue:)) { config.layout = layout }
        let model = BoardModel(config: config)
        model.reload()
        if let path = value("--remote"),
           let data = FileManager.default.contents(atPath: path),
           let remote = try? JSONDecoder().decode(RemoteState.self, from: data) {
            model.setRemoteForPreview(remote)
        }
        model.expandedSubtasks = ids("--expand")
        model.expandedDetails = ids("--details")

        let content: AnyView
        if let tab = value("--settings").flatMap(SettingsTab.init(rawValue:)) {
            content = AnyView(SettingsView(model: model, tab: tab).background(Color(nsColor: .windowBackgroundColor)))
        } else {
            content = AnyView(BoardView(model: model, opaque: true))
        }

        let appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.contentView = hosting
        window.orderBack(nil)

        // Give SwiftUI a few turns of the run loop to lay out and load images.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: output))
        } catch {
            FileHandle.standardError.write(Data("Could not write \(output): \(error)\n".utf8))
            return 1
        }
        print("Wrote \(output) (\(Int(size.width))×\(Int(size.height)))")
        return 0
    }
}
