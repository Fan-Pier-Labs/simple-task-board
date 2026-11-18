import SwiftUI
import TaskBoardCore

struct BoardActions {
    var openSettings: () -> Void = {}
}

/// The whole board, as shown under the menu bar icon.
struct BoardView: View {
    @ObservedObject var model: BoardModel
    var actions = BoardActions()
    /// A popover brings its own background; a plain window or a snapshot needs one drawn.
    var opaque = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isEmpty {
                emptyState
            } else {
                switch model.config.layout {
                case .board: boardLayout
                case .list: listLayout
                }
            }
            if !model.syncNotes.isEmpty {
                Divider()
                notes
            }
        }
        .frame(width: model.preferredSize.width, height: model.preferredSize.height)
        .background(opaque ? Color(nsColor: .windowBackgroundColor) : Color.clear)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Task Board").font(.system(size: 13, weight: .semibold))
            if model.summary.working > 0 {
                SummaryPill(status: .working, count: model.summary.working, label: "working")
            }
            if model.summary.needsAttention > 0 {
                SummaryPill(
                    status: .needsAttention, count: model.summary.needsAttention,
                    label: model.summary.needsAttention == 1 ? "needs you" : "need you"
                )
            }
            Spacer(minLength: 8)
            if model.isSyncing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            }
            IconButton(systemName: "arrow.clockwise", help: refreshHelp) {
                model.reload()
                Task { await model.syncRemote() }
            }
            IconButton(
                systemName: model.config.layout == .board ? "list.bullet" : "rectangle.split.3x1",
                help: model.config.layout == .board ? "Show as a list" : "Show as columns"
            ) {
                model.updateConfig { $0.layout = $0.layout == .board ? .list : .board }
            }
            IconButton(
                systemName: model.pinned ? "pin.fill" : "pin",
                help: model.pinned ? "Unpin: close when you click elsewhere" : "Pin: keep the board open",
                active: model.pinned
            ) {
                model.pinned.toggle()
            }
            IconButton(systemName: "gearshape", help: "Settings", action: actions.openSettings)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var refreshHelp: String {
        guard let lastSync = model.lastSync else { return "Refresh now" }
        return "Refresh now. GitHub and Jira last checked \(lastSync.formatted(.relative(presentation: .named)))."
    }

    // MARK: - Layouts

    private var boardLayout: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.columns) { column in
                    VStack(alignment: .leading, spacing: 8) {
                        ColumnHeader(column: column)
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 6) {
                                ForEach(column.nodes) { node in
                                    TaskCardView(node: node, model: model, titleLines: 2)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(width: BoardModel.columnWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                }
            }
            .padding(10)
        }
    }

    private var listLayout: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(model.columns) { column in
                    ColumnHeader(column: column).padding(.top, 6)
                    if column.nodes.isEmpty {
                        Text("Nothing here").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 2)
                    }
                    ForEach(column.nodes) { node in
                        TaskCardView(node: node, model: model, titleLines: 1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("No tasks yet").font(.system(size: 14, weight: .semibold))
            Text("Tasks are markdown files in:")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text((model.tasksDirectory.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Create one with  `taskboard add \"Title\"`,  or install the Cursor hooks in Settings and start an agent.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Open Settings", action: actions.openSettings)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.syncNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct ColumnHeader: View {
    let column: BoardColumn

    var body: some View {
        HStack(spacing: 6) {
            Text(column.column.name).font(.system(size: 12, weight: .semibold))
            Text("\(column.nodes.count)").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}

private struct SummaryPill: View {
    let status: TaskStatus
    let count: Int
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            StatusIconView(status: status, size: 11)
            Text("\(count) \(label)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
