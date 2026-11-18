import AppKit
import SwiftUI
import TaskBoardCore

/// The small status glyph on every card: spinner, attention, done or idle.
struct StatusIconView: View {
    let status: TaskStatus
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch status {
            case .working:
                SpinnerView(size: size - 2)
            case .needsAttention:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .idle:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: size))
        .frame(width: size + 2, height: size + 2)
        .accessibilityLabel(status.label)
    }
}

struct SpinnerView: View {
    let size: CGFloat
    @State private var spinning = false

    var body: some View {
        let lineWidth = max(1.5, size / 7)
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.62)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: size, height: size)
        .onAppear { spinning = true }
    }
}

enum Icons {
    /// The GitHub mark, drawn as a template image so it follows the text colour.
    static let github: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 .297c-6.63 0-12 5.373-12 12 \
        0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61\
        -4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 \
        1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466\
        -5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98\
        -.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176\
        .765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896\
        -.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8))
            ?? NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Pull request")
            ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    /// The agent app's own icon, read from the installed app rather than shipped with this one.
    /// The app is found by asking which one opens its links.
    @MainActor
    static func appIcon(for kind: AgentKind) -> NSImage? {
        if let cached = appIcons[kind] { return cached }
        var icon: NSImage?
        if let probe = URL(string: "\(kind.rawValue)://open"),
           let app = NSWorkspace.shared.urlForApplication(toOpen: probe) {
            icon = NSWorkspace.shared.icon(forFile: app.path)
            icon?.size = NSSize(width: 32, height: 32)
        }
        appIcons[kind] = .some(icon)
        return icon
    }

    @MainActor private static var appIcons: [AgentKind: NSImage?] = [:]
}

/// A borderless button that highlights on hover, sized for a card's icon row.
struct HoverButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        HoverButton(help: help, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
    }
}
