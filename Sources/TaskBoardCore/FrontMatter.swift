import Foundation

/// A markdown document with an optional leading `---` front matter block.
///
/// Only flat `key: value` pairs are understood. Anything else inside the block
/// (nested YAML, lists, comments) is kept verbatim, and unknown keys keep their
/// position, so a file another tool wrote round-trips without losing data.
public struct FrontMatterDocument: Equatable {
    public struct Field: Equatable {
        /// Empty for a line that is not a `key: value` pair; `value` then holds the raw line.
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var fields: [Field]
    public var body: String

    public init(fields: [Field] = [], body: String = "") {
        self.fields = fields
        self.body = body
    }

    /// Reads or replaces a value. Setting `nil` or an empty string removes the key.
    public subscript(key: String) -> String? {
        get { fields.first { $0.key == key }?.value }
        set {
            if let newValue, !newValue.isEmpty {
                if let index = fields.firstIndex(where: { $0.key == key }) {
                    fields[index].value = newValue
                } else {
                    fields.append(Field(key: key, value: newValue))
                }
            } else {
                fields.removeAll { $0.key == key }
            }
        }
    }

    public static func parse(_ text: String) -> FrontMatterDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let first = lines.first, isDelimiter(first),
              let end = lines.indices.dropFirst().first(where: { isDelimiter(lines[$0]) })
        else {
            return FrontMatterDocument(fields: [], body: normalized)
        }

        var fields: [Field] = []
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let isPlainPair = !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("- ")
            if isPlainPair, let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    fields.append(Field(key: key, value: unquote(raw)))
                    continue
                }
            }
            fields.append(Field(key: "", value: line))
        }

        var bodyLines = Array(lines[(end + 1)...])
        if let firstBody = bodyLines.first, firstBody.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.removeFirst()
        }
        return FrontMatterDocument(fields: fields, body: bodyLines.joined(separator: "\n"))
    }

    public func serialized() -> String {
        var out = "---\n"
        for field in fields {
            if field.key.isEmpty {
                out += field.value + "\n"
            } else {
                out += "\(field.key): \(Self.quoteIfNeeded(field.value))\n"
            }
        }
        out += "---\n"
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            out += "\n" + trimmedBody + "\n"
        }
        return out
    }

    // MARK: - Scalars

    private static func isDelimiter(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "---"
    }

    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, let first = raw.first, let last = raw.last else { return raw }
        let inner = String(raw.dropFirst().dropLast())
        if first == "\"", last == "\"" {
            var result = ""
            var escaping = false
            for character in inner {
                if escaping {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if first == "'", last == "'" {
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    static func quoteIfNeeded(_ value: String) -> String {
        let reserved: Set<String> = ["true", "false", "yes", "no", "null", "~", "on", "off"]
        let hazardousStart = CharacterSet(charactersIn: "!&*-?|>'\"%@`[]{},#")
        var needsQuotes = value.isEmpty
            || value != value.trimmingCharacters(in: .whitespaces)
            || value.contains(": ") || value.contains(" #")
            || value.contains("\n") || value.contains("\t")
            || value.hasSuffix(":")
            || reserved.contains(value.lowercased())
        if let scalar = value.unicodeScalars.first, hazardousStart.contains(scalar) {
            needsQuotes = true
        }
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
