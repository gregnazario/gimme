import Foundation

/// A minimal TOML value tree for the subset gimme formulae and config use:
/// tables, array-of-tables, key/value pairs of string/int/double/bool, and
/// inline arrays of scalars. Nested dotted table headers `[a.b.c]` and
/// array-of-table headers `[[name]]` are supported.
public indirect enum TOMLValue: Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table(TOMLTable)

    public var asTable: TOMLTable? {
        if case .table(let t) = self { return t }
        return nil
    }
    public var asArray: [TOMLValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var asInteger: Int? {
        if case .integer(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
    public var asDouble: Double? {
        if case .double(let d) = self { return d }
        if case .integer(let i) = self { return Double(i) }
        return nil
    }
    public var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

/// Ordered-ish table: a wrapper around [String: TOMLValue] with typed accessors.
public struct TOMLTable: Equatable {
    public var children: [String: TOMLValue]

    public init(_ children: [String: TOMLValue] = [:]) { self.children = children }

    public func string(_ key: String) -> String? { children[key]?.asString }
    public func integer(_ key: String) -> Int? { children[key]?.asInteger }
    public func double(_ key: String) -> Double? { children[key]?.asDouble }
    public func bool(_ key: String) -> Bool? { children[key]?.asBool }
    public func array(_ key: String) -> [TOMLValue]? { children[key]?.asArray }
    public func table(_ key: String) -> TOMLTable? { children[key]?.asTable }

    public static func == (lhs: TOMLTable, rhs: TOMLTable) -> Bool {
        lhs.children == rhs.children
    }
}

public enum TOMLError: Error, Equatable {
    case parse(String)
    case typeMismatch(String)
}

public enum TOML {
    /// Parse a TOML string into the root table.
    public static func parse(_ text: String) throws -> TOMLTable {
        var root: TOMLTable = TOMLTable()
        var currentPath: [String] = []

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (lineNo, raw) in lines.enumerated() {
            let stripped = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }

            if stripped.hasPrefix("[[") {
                guard stripped.hasSuffix("]]") else {
                    throw TOMLError.parse("line \(lineNo+1): malformed array-of-table header")
                }
                let header = String(stripped.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                let parts = parseDottedKey(header)
                try appendArrayOfTables(into: &root, path: parts)
                currentPath = parts
                continue
            }

            if stripped.hasPrefix("[") {
                guard stripped.hasSuffix("]") else {
                    throw TOMLError.parse("line \(lineNo+1): malformed table header")
                }
                let header = String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentPath = parseDottedKey(header)
                ensureTable(into: &root, path: currentPath)
                continue
            }

            // key = value
            guard let eq = stripped.firstIndex(of: "=") else {
                throw TOMLError.parse("line \(lineNo+1): expected '=' in: \(stripped)")
            }
            let key = String(stripped[..<eq]).trimmingCharacters(in: .whitespaces)
            let valueStr = String(stripped[stripped.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let value = try parseValue(valueStr, lineNo: lineNo + 1)
            try setInto(&root, path: currentPath + parseDottedKey(key), value: value)
        }
        return root
    }

    public static func parseData(_ data: Data) throws -> TOMLTable {
        guard let s = String(data: data, encoding: .utf8) else {
            throw TOMLError.parse("config is not valid UTF-8")
        }
        return try parse(s)
    }
}

// MARK: - Helpers

private func stripComment(_ line: String) -> String {
    // Strip `# ...` comments but ignore `#` inside string literals. Track `\`
    // escapes inside basic strings so an escaped quote (`\"`) doesn't wrongly
    // toggle the string closed and expose a later `#` as a comment.
    var result = ""
    var inBasic = false
    var inLiteral = false
    var escaped = false
    for ch in line {
        if escaped {
            // Previous char was a backslash inside a basic string; this char is
            // literal (consumed by the escape), append and clear escape state.
            result.append(ch)
            escaped = false
            continue
        }
        switch ch {
        case "\\":
            if inBasic { escaped = true }
            result.append(ch)
        case "\"":
            if !inLiteral { inBasic.toggle() }
            result.append(ch)
        case "'":
            if !inBasic { inLiteral.toggle() }
            result.append(ch)
        case "#":
            if !inBasic && !inLiteral { return result }
            result.append(ch)
        default:
            result.append(ch)
        }
    }
    return result
}

/// Parse a dotted key like `package` or `install.step` into components,
/// respecting quoted segments.
private func parseDottedKey(_ key: String) -> [String] {
    return key.split(separator: ".").map { String($0).trimmingCharacters(in: .whitespaces) }
}

private func ensureTable(into root: inout TOMLTable, path: [String]) {
    if path.isEmpty { return }
    var ref: TOMLTable = root
    for k in path {
        if let existing = ref.children[k]?.asTable {
            ref = existing
        } else {
            let newTable = TOMLTable()
            ref.children[k] = .table(newTable)
            ref = newTable
        }
    }
}

/// For `[[a.b]]`: navigate/ensure intermediate tables, then append a fresh
/// table to the array at the leaf. Writes propagate back through `inout`
/// because TOMLTable is a value type.
private func appendArrayOfTables(into root: inout TOMLTable, path: [String]) throws {
    guard let leaf = path.last else { throw TOMLError.parse("empty array-of-table header") }
    let parents = Array(path.dropLast())
    try appendAOTRec(&root, parents: parents, leaf: leaf)
}

private func appendAOTRec(_ table: inout TOMLTable, parents: [String], leaf: String) throws {
    if parents.isEmpty {
        let newTable = TOMLTable()
        if let existing = table.children[leaf]?.asArray {
            var arr = existing
            arr.append(.table(newTable))
            table.children[leaf] = .array(arr)
        } else {
            table.children[leaf] = .array([.table(newTable)])
        }
        return
    }
    let head = parents[0]
    let rest = Array(parents.dropFirst())
    if let existing = table.children[head]?.asTable {
        var sub = existing
        try appendAOTRec(&sub, parents: rest, leaf: leaf)
        table.children[head] = .table(sub)
    } else if let arr = table.children[head]?.asArray, let last = arr.last?.asTable {
        // Descending through an array-of-tables parent: mutate its last element.
        var a = arr
        var sub = last
        try appendAOTRec(&sub, parents: rest, leaf: leaf)
        a[a.count - 1] = .table(sub)
        table.children[head] = .array(a)
    } else {
        var sub = TOMLTable()
        try appendAOTRec(&sub, parents: rest, leaf: leaf)
        table.children[head] = .table(sub)
    }
}

/// Set a value at a dotted path inside `root`, creating intermediate tables.
/// For paths that traverse an array-of-tables, set into the *last* element.
private func setInto(_ root: inout TOMLTable, path: [String], value: TOMLValue) throws {
    try setIntoRef(&root, path: path, value: value)
}

private func setIntoRef(_ table: inout TOMLTable, path: [String], value: TOMLValue) throws {
    if path.count == 1 {
        table.children[path[0]] = value
        return
    }
    let head = path[0]
    let rest = Array(path.dropFirst())
    if let existing = table.children[head] {
        switch existing {
        case .table(var sub):
            try setIntoRef(&sub, path: rest, value: value)
            table.children[head] = .table(sub)
        case .array(var arr):
            // Array-of-tables: mutate the last element in place.
            guard let last = arr.last, let sub = last.asTable else {
                throw TOMLError.parse("cannot descend into non-table array element at \(head)")
            }
            var s = sub
            try setIntoRef(&s, path: rest, value: value)
            arr[arr.count - 1] = .table(s)
            table.children[head] = .array(arr)
        default:
            throw TOMLError.parse("key \(head) is a scalar, cannot descend")
        }
    } else {
        var sub = TOMLTable()
        try setIntoRef(&sub, path: rest, value: value)
        table.children[head] = .table(sub)
    }
}

/// Parse a value literal (string basic/literal, int, double, bool, inline array).
private func parseValue(_ raw: String, lineNo: Int) throws -> TOMLValue {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { throw TOMLError.parse("line \(lineNo): empty value") }

    // Basic string "..."
    if s.hasPrefix("\"") {
        return .string(try parseBasicString(s, lineNo: lineNo))
    }
    // Literal string '...'
    if s.hasPrefix("'") {
        guard let end = s.dropFirst().firstIndex(of: "'") else {
            throw TOMLError.parse("line \(lineNo): unterminated literal string")
        }
        return .string(String(s[s.index(after: s.startIndex)..<end]))
    }
    // Inline array
    if s.hasPrefix("[") {
        return try parseArray(s, lineNo: lineNo)
    }
    // Inline table { k = v, k = v }
    if s.hasPrefix("{") {
        return try parseInlineTable(s, lineNo: lineNo)
    }
    // Bool
    if s == "true" { return .bool(true) }
    if s == "false" { return .bool(false) }
    // Integer
    if let i = Int(s) { return .integer(i) }
    // Double
    if let d = Double(s) { return .double(d) }
    throw TOMLError.parse("line \(lineNo): unparseable value: \(s)")
}

private func parseBasicString(_ raw: String, lineNo: Int) throws -> String {
    var iter = raw.makeIterator()
    guard iter.next() == "\"" else { throw TOMLError.parse("line \(lineNo): expected basic string") }
    var result = ""
    var escaped = false
    while let ch = iter.next() {
        if escaped {
            switch ch {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            default: result.append(ch)
            }
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if ch == "\"" {
            return result
        } else {
            result.append(ch)
        }
    }
    throw TOMLError.parse("line \(lineNo): unterminated basic string")
}

private func parseArray(_ raw: String, lineNo: Int) throws -> TOMLValue {
    var inner = raw.trimmingCharacters(in: .whitespaces)
    guard inner.hasPrefix("["), inner.hasSuffix("]") else {
        throw TOMLError.parse("line \(lineNo): malformed array")
    }
    inner = String(inner.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    if inner.isEmpty { return .array([]) }

    var items: [TOMLValue] = []
    var current = ""
    var inBasic = false, inLiteral = false
    for ch in inner {
        switch ch {
        case "\"":
            if !inLiteral { inBasic.toggle() }
            current.append(ch)
        case "'":
            if !inBasic { inLiteral.toggle() }
            current.append(ch)
        case ",":
            if !inBasic && !inLiteral {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { items.append(try parseValue(trimmed, lineNo: lineNo)) }
                current = ""
            } else {
                current.append(ch)
            }
        default:
            current.append(ch)
        }
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty { items.append(try parseValue(last, lineNo: lineNo)) }
    return .array(items)
}

/// Parse an inline table: `{ k = v, k = v }`. Keys/values are scalar/array only.
private func parseInlineTable(_ raw: String, lineNo: Int) throws -> TOMLValue {
    var inner = raw.trimmingCharacters(in: .whitespaces)
    guard inner.hasPrefix("{"), inner.hasSuffix("}") else {
        throw TOMLError.parse("line \(lineNo): malformed inline table")
    }
    inner = String(inner.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    var table = TOMLTable()
    if inner.isEmpty { return .table(table) }

    var current = ""
    var inBasic = false, inLiteral = false
    var entries: [String] = []
    for ch in inner {
        switch ch {
        case "\"":
            if !inLiteral { inBasic.toggle() }
            current.append(ch)
        case "'":
            if !inBasic { inLiteral.toggle() }
            current.append(ch)
        case ",":
            if !inBasic && !inLiteral {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { entries.append(trimmed) }
                current = ""
            } else {
                current.append(ch)
            }
        default:
            current.append(ch)
        }
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty { entries.append(last) }

    for entry in entries {
        guard let eq = entry.firstIndex(of: "=") else {
            throw TOMLError.parse("line \(lineNo): inline table entry missing '=': \(entry)")
        }
        let key = String(entry[..<eq]).trimmingCharacters(in: .whitespaces)
        let valStr = String(entry[entry.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        table.children[key] = try parseValue(valStr, lineNo: lineNo)
    }
    return .table(table)
}

/// A small generic decoder bridge: decode a Decodable type from a TOML file
/// by going through JSON. Used where Codable ergonomics matter (Formula, etc.).
public struct TOMLDecoder {
    public init() {}
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let table = try TOML.parseData(data)
        let json = try JSONSerialization.data(withJSONObject: table.toJSON(), options: [])
        return try JSONDecoder().decode(type, from: json)
    }
}

extension TOMLTable {
    /// Convert to a JSON-serializable object (for TOMLDecoder).
    func toJSON() -> Any {
        var dict: [String: Any] = [:]
        for (k, v) in children {
            dict[k] = v.toJSON()
        }
        return dict
    }
}

extension TOMLValue {
    func toJSON() -> Any {
        switch self {
        case .string(let s):  return s
        case .integer(let i): return i
        case .double(let d):  return d
        case .bool(let b):    return b
        case .array(let a):   return a.map { $0.toJSON() }
        case .table(let t):   return t.toJSON()
        }
    }
}
