// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "simple-task-board",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TaskBoardCore", targets: ["TaskBoardCore"]),
        .executable(name: "TaskBoardApp", targets: ["TaskBoardApp"]),
        .executable(name: "taskboard", targets: ["taskboard"]),
    ],
    targets: [
        // Model, markdown storage, status roll-up and integrations. No UI.
        .target(name: "TaskBoardCore"),
        // The menu bar app.
        .executableTarget(name: "TaskBoardApp", dependencies: ["TaskBoardCore"]),
        // The CLI that agents and Cursor hooks use to write tasks.
        .executableTarget(name: "taskboard", dependencies: ["TaskBoardCore"]),
        .testTarget(name: "TaskBoardCoreTests", dependencies: ["TaskBoardCore"]),
    ]
)
