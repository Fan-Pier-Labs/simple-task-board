import AppKit

// Task Board: a menu bar app. It has no Dock icon and no main window.

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let arguments = CommandLine.arguments
    if arguments.contains("--snapshot") {
        exit(Snapshot.run(arguments: arguments))
    }

    // `NSApplication.delegate` is weak; this local keeps the delegate alive for the life of `run()`.
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
