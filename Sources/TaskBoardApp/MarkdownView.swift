import SwiftUI

/// The block-level pieces of a task description. Inline styling is left to `AttributedString`.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `checked` is `nil` for a plain list item, and set for a `- [ ]` checkbox.
    case item(marker: String, text: String, indent: Int, checked: Bool?)
    case code(String)
    case quote(String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if code != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if ["---", "***", "___"].contains(trimmed) {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }

            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
                flush()
                blocks.append(.heading(level: hashes, text: trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if let item = listItem(line) {
                flush()
                blocks.append(item)
                continue
            }

            if !quote.isEmpty { flush() }
            paragraph.append(trimmed)
        }

        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let marker = String(trimmed[..<space])
        var rest = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)

        let isBullet = ["-", "*", "+"].contains(marker)
        let digits = marker.dropLast()
        let isNumbered = marker.count >= 2 && (marker.hasSuffix(".") || marker.hasSuffix(")"))
            && !digits.isEmpty && digits.allSatisfy(\.isNumber)
        guard isBullet || isNumbered else { return nil }

        var checked: Bool?
        if isBullet {
            let lowered = rest.lowercased()
            if lowered.hasPrefix("[ ]") { checked = false } else if lowered.hasPrefix("[x]") { checked = true }
            if checked != nil { rest = rest.dropFirst(3).trimmingCharacters(in: .whitespaces) }
        }
        return .item(marker: isBullet ? "•" : marker, text: rest, indent: indent / 2, checked: checked)
    }
}

/// Renders a task's markdown body: headings, lists, checkboxes, quotes and code blocks.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.system(size: 12))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level <= 1 ? 14 : (level == 2 ? 13 : 12), weight: .semibold))
                .padding(.top, 2)

        case .paragraph(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)

        case .item(let marker, let text, let indent, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                } else {
                    Text(marker).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(inline(text))
                    .strikethrough(checked == true, color: .secondary)
                    .foregroundStyle(checked == true ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .code(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))

        case .quote(let text):
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.2)).frame(width: 2)
                Text(inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

        case .rule:
            Divider()
        }
    }
}
