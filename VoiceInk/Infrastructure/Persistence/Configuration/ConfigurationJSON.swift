import Foundation

enum ConfigurationError: LocalizedError {
    case invalid(String)
    case externalChange

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "Invalid configuration: \(detail)"
        case .externalChange:
            return "The configuration file changed outside VoiceInk. Quit and reopen VoiceInk to load it. Automatic saving is paused."
        }
    }
}

enum ConfigurationValue: Codable, Equatable {
    case object([String: ConfigurationValue])
    case array([ConfigurationValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([String: Self].self) { self = .object(decoded) }
        else { self = .array(try value.decode([Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data())
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    var object: [String: Self]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    var propertyList: Any {
        switch self {
        case .object(let object): return object.mapValues(\.propertyList)
        case .array(let array): return array.map(\.propertyList)
        case .string(let string): return string
        case .number(let number): return number
        case .bool(let bool): return bool
        case .null: return NSNull()
        }
    }
}

/// Keeps source ranges so changing a preference does not discard the user's comments.
struct ConfigurationJSON {
    struct Node {
        let range: Range<Int>
        let value: ConfigurationValue
        var members: [String: Node] = [:]
        var elements: [Node] = []
        var lastValueEnd: Int?
        var trailingComma = false
    }

    let data: Data
    let root: Node

    init(data: Data) throws {
        guard data.count <= 16 * 1_024 * 1_024, String(data: data, encoding: .utf8) != nil else {
            throw ConfigurationError.invalid("Use a UTF-8 file smaller than 16 MB.")
        }
        var parser = Parser(bytes: Array(data))
        root = try parser.parse()
        self.data = data
    }

    func updating(_ value: ConfigurationValue) throws -> Data {
        var edits: [(Range<Int>, Data)] = []
        try update(root, to: value, edits: &edits)
        var result = data
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private func update(_ node: Node, to value: ConfigurationValue, edits: inout [(Range<Int>, Data)]) throws {
        guard node.value != value else { return }
        if case .object(let old) = node.value, case .object(let new) = value,
            Set(old.keys).isSubset(of: Set(new.keys))
        {
            for key in old.keys.sorted() {
                if let child = node.members[key], let replacement = new[key] {
                    try update(child, to: replacement, edits: &edits)
                }
            }
            let added = Set(new.keys).subtracting(old.keys).sorted()
            if !added.isEmpty {
                let insertion = node.range.upperBound - 1
                var prefix = ""
                if let end = node.lastValueEnd, !node.trailingComma {
                    if end == insertion { prefix = "," }
                    else { edits.append((end..<end, Data(",".utf8))) }
                }
                let members = try added.map { key in
                    let name = String(decoding: try ConfigurationValue.string(key).data(), as: UTF8.self)
                    let content = String(decoding: try new[key]!.data(), as: UTF8.self)
                    return "\(name): \(content)"
                }.joined(separator: ",\n")
                edits.append((insertion..<insertion, Data("\(prefix)\n\(members)\n".utf8)))
            }
        } else if case .array(let old) = node.value, case .array(let new) = value, old.count == new.count {
            for (child, replacement) in zip(node.elements, new) {
                try update(child, to: replacement, edits: &edits)
            }
        } else {
            edits.append((node.range, try value.data()))
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func parse() throws -> Node {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { offset = 3 }
            let node = try value(depth: 0)
            try trivia()
            guard offset == bytes.count else { throw error("Unexpected content after the root object") }
            return node
        }

        mutating func value(depth: Int) throws -> Node {
            guard depth < 64 else { throw error("Nesting is too deep") }
            try trivia()
            let start = offset
            guard offset < bytes.count else { throw error("Expected a value") }
            switch bytes[offset] {
            case 123, 91:
                let isObject = bytes[offset] == 123
                let close: UInt8 = isObject ? 125 : 93
                offset += 1
                var members: [String: Node] = [:]
                var elements: [Node] = []
                var lastValueEnd: Int?
                var trailingComma = false
                try trivia()
                while offset < bytes.count, bytes[offset] != close {
                    var key: String?
                    if isObject {
                        let keyNode = try string()
                        guard case .string(let name) = keyNode.value else { throw error("Expected a key") }
                        guard members[name] == nil else { throw error("Duplicate key") }
                        key = name
                        try trivia()
                        try consume(58)
                    }
                    let child = try value(depth: depth + 1)
                    if let key { members[key] = child } else { elements.append(child) }
                    lastValueEnd = offset
                    try trivia()
                    if offset < bytes.count, bytes[offset] == 44 {
                        offset += 1
                        try trivia()
                        trailingComma = offset < bytes.count && bytes[offset] == close
                    } else { break }
                }
                try consume(close)
                return Node(
                    range: start..<offset,
                    value: isObject ? .object(members.mapValues(\.value)) : .array(elements.map(\.value)),
                    members: members, elements: elements, lastValueEnd: lastValueEnd, trailingComma: trailingComma
                )
            case 34: return try string()
            default:
                while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125, 47].contains(bytes[offset]) {
                    offset += 1
                }
                guard offset > start,
                    let decoded = try? JSONDecoder().decode(ConfigurationValue.self, from: Data(bytes[start..<offset]))
                else { throw error("Expected a JSON value") }
                return Node(range: start..<offset, value: decoded)
            }
        }

        mutating func string() throws -> Node {
            let start = offset
            try consume(34)
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == 92 {
                    guard offset < bytes.count else { break }
                    offset += 1
                } else if byte == 34 {
                    guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else {
                        throw error("Invalid string")
                    }
                    return Node(range: start..<offset, value: .string(text))
                }
            }
            throw error("Unterminated string")
        }

        mutating func trivia() throws {
            while offset < bytes.count {
                if [9, 10, 13, 32].contains(bytes[offset]) { offset += 1; continue }
                guard offset + 1 < bytes.count, bytes[offset] == 47 else { return }
                if bytes[offset + 1] == 47 {
                    offset += 2
                    while offset < bytes.count, ![10, 13].contains(bytes[offset]) { offset += 1 }
                } else if bytes[offset + 1] == 42 {
                    offset += 2
                    while offset + 1 < bytes.count, !(bytes[offset] == 42 && bytes[offset + 1] == 47) { offset += 1 }
                    guard offset + 1 < bytes.count else { throw error("Unterminated comment") }
                    offset += 2
                } else { return }
            }
        }

        mutating func consume(_ byte: UInt8) throws {
            guard offset < bytes.count, bytes[offset] == byte else { throw error("Unexpected token") }
            offset += 1
        }

        func error(_ message: String) -> ConfigurationError {
            let line = bytes[..<offset].filter { $0 == 10 }.count + 1
            return .invalid("\(message) at line \(line).")
        }
    }
}
