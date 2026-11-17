import Foundation
import GotItDomain

/// Structural changes, including a character splice for text. Unchanged blocks and
/// media never enter the history payload. Character offsets cannot split emoji.
indirect enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let n = try? c.decode(Int64.self) { self = .integer(n) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

extension JSONValue {
    /// The JSON of an `Encodable` value. Used for every block an edit changes and, on undo and
    /// redo, for the whole note.
    static func of<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        // `init(from:)` finds what each value is by trying one type after another, and every
        // wrong guess is a thrown error: several per value, thousands for a note. That was most
        // of the cost of recording an edit. Reading the text directly gives the same value; if
        // it ever cannot read something, the decoder still does.
        if let parsed = try? JSONText.parse(data) { return parsed }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// A reader of JSON text (RFC 8259) into `JSONValue`, with the same result as decoding it:
/// a number written without fraction or exponent that fits 64 bits is an integer, any other a
/// double; `true`/`false` are booleans; text is unescaped (`\uXXXX` pairs included).
enum JSONText {
    struct Malformed: Error {}

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            var reader = Reader(bytes: raw.bindMemory(to: UInt8.self))
            let value = try reader.value(depth: 0)
            reader.skipSpace()
            guard reader.index == reader.bytes.count else { throw Malformed() }
            return value
        }
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 { index += 1 }
        }

        private mutating func expect(_ word: StaticString) throws {
            let count = word.utf8CodeUnitCount
            guard index + count <= bytes.count else { throw Malformed() }
            for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] { throw Malformed() }
            index += count
        }

        mutating func value(depth: Int) throws -> JSONValue {
            // Notes are a few levels deep; a limit keeps a damaged text from exhausting the stack.
            guard depth < 256 else { throw Malformed() }
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var object: [String: JSONValue] = [:]
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Malformed() }
                    index += 1
                    object[key] = try value(depth: depth + 1)
                    skipSpace()
                    guard index < bytes.count else { throw Malformed() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "}") else { throw Malformed() }
                    index += 1
                    return .object(object)
                }
            case UInt8(ascii: "["):
                index += 1
                var array: [JSONValue] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
                while true {
                    array.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw Malformed() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "]") else { throw Malformed() }
                    index += 1
                    return .array(array)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try number()
            }
        }

        private mutating func number() throws -> JSONValue {
            let start = index
            var whole = true
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            let digits = index
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") { index += 1 }
            guard index > digits else { throw Malformed() }
            // No leading zeros ("01"): not JSON.
            if index - digits > 1, bytes[digits] == UInt8(ascii: "0") { throw Malformed() }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                whole = false; index += 1
                let fraction = index
                while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") { index += 1 }
                guard index > fraction else { throw Malformed() }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                whole = false; index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                let exponent = index
                while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") { index += 1 }
                guard index > exponent else { throw Malformed() }
            }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
            if whole, let integer = Int64(text) { return .integer(integer) }
            guard let double = Double(text), double.isFinite else { throw Malformed() }
            return .number(double)
        }

        private mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw Malformed() }
            var unit: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]; index += 1
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): unit = unit << 4 | UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): unit = unit << 4 | UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): unit = unit << 4 | UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw Malformed()
                }
            }
            return unit
        }

        private mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Malformed() }
            index += 1
            var start = index
            var pieces: [UInt8]?
            while true {
                guard index < bytes.count else { throw Malformed() }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    defer { index += 1 }
                    let last = UnsafeBufferPointer(rebasing: bytes[start..<index])
                    // Nearly every text has no escape: it is read where it is, in one piece.
                    guard var pieces else { return try text(last) }
                    pieces.append(contentsOf: last)
                    return try pieces.withUnsafeBufferPointer { try text($0) }
                }
                guard byte >= 0x20 else { throw Malformed() }        // control characters are always escaped
                guard byte == UInt8(ascii: "\\") else { index += 1; continue }
                if pieces == nil { pieces = [] }
                pieces?.append(contentsOf: bytes[start..<index])
                index += 1
                guard index < bytes.count else { throw Malformed() }
                let escaped = bytes[index]; index += 1
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): pieces?.append(escaped)
                case UInt8(ascii: "b"): pieces?.append(0x08)
                case UInt8(ascii: "f"): pieces?.append(0x0C)
                case UInt8(ascii: "n"): pieces?.append(0x0A)
                case UInt8(ascii: "r"): pieces?.append(0x0D)
                case UInt8(ascii: "t"): pieces?.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // The first half of a pair: the second must follow, also escaped.
                        guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { throw Malformed() }
                        index += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw Malformed() }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let unicode = Unicode.Scalar(scalar) else { throw Malformed() }
                    pieces?.append(contentsOf: Array(String(Character(unicode)).utf8))
                default: throw Malformed()
                }
                start = index
            }
        }

        /// Text from UTF-8 that must be valid as it is (nothing replaced).
        private func text(_ utf8: UnsafeBufferPointer<UInt8>) throws -> String {
            guard let text = String(validating: utf8, as: UTF8.self) else { throw Malformed() }
            return text
        }
    }
}

struct DocumentDelta: Codable {
    enum Component: Codable { case key(String), index(Int) }
    enum Operation: Codable {
        case replace(JSONValue?)
        case text(offset: Int, remove: Int, insert: String)
        case array(offset: Int, remove: Int, insert: [JSONValue])
    }
    struct Edit: Codable { var path: [Component]; var operation: Operation }
    var edits: [Edit]

    static func between(_ before: CanvasDocument, _ after: CanvasDocument) throws -> Self {
        func value<T: Encodable>(_ value: T) throws -> JSONValue { try JSONValue.of(value) }
        // Compare typed values first. Encoding the whole note just to find a one-letter
        // difference would move the original performance problem into the delta builder.
        func header(_ doc: CanvasDocument) -> CanvasDocument {
            var d = doc; d.revision = 0; d.createdAt = .distantPast; d.updatedAt = .distantPast
            d.blocks = []; d.assets = []; d.relations = []
            return d
        }
        var edits: [Edit] = []
        let oldHeader = header(before), newHeader = header(after)
        if oldHeader != newHeader { diff(try value(oldHeader), try value(newHeader), path: [], edits: &edits) }
        func array<T: Codable & Equatable>(_ old: [T], _ new: [T], key: String) throws {
            if old.count == new.count {
                for i in old.indices where old[i] != new[i] {
                    diff(try value(old[i]), try value(new[i]), path: [.key(key), .index(i)], edits: &edits)
                }
            } else {
                let (prefix, suffix) = edges(old, new)
                let inserted = try new[prefix..<(new.count - suffix)].map { try value($0) }
                edits.append(.init(path: [.key(key)], operation: .array(offset: prefix, remove: old.count - prefix - suffix, insert: inserted)))
            }
        }
        try array(before.blocks, after.blocks, key: "blocks")
        try array(before.assets, after.assets, key: "assets")
        try array(before.relations, after.relations, key: "relations")
        return .init(edits: edits)
    }

    private static func diff(_ a: JSONValue, _ b: JSONValue, path: [Component], edits: inout [Edit]) {
        guard a != b else { return }
        switch (a, b) {
        case (.object(let x), .object(let y)):
            for key in Set(x.keys).union(y.keys).sorted() {
                let p = path + [.key(key)]
                if let old = x[key], let new = y[key] { diff(old, new, path: p, edits: &edits) }
                else { edits.append(.init(path: p, operation: .replace(y[key]))) }
            }
        case (.string(let x), .string(let y)):
            let old = Array(x), new = Array(y)
            let (prefix, suffix) = edges(old, new)
            edits.append(.init(path: path, operation: .text(offset: prefix, remove: old.count - prefix - suffix,
                insert: String(new[prefix..<(new.count - suffix)]))))
        case (.array(let x), .array(let y)):
            if x.count == y.count {
                for i in x.indices { diff(x[i], y[i], path: path + [.index(i)], edits: &edits) }
            } else {
                let (prefix, suffix) = edges(x, y)
                edits.append(.init(path: path, operation: .array(offset: prefix, remove: x.count - prefix - suffix,
                    insert: Array(y[prefix..<(y.count - suffix)]))))
            }
        default: edits.append(.init(path: path, operation: .replace(b)))
        }
    }
    private static func edges<T: Equatable>(_ a: [T], _ b: [T]) -> (Int, Int) {
        var p = 0, s = 0
        while p < min(a.count, b.count), a[p] == b[p] { p += 1 }
        while s < min(a.count, b.count) - p, a[a.count - s - 1] == b[b.count - s - 1] { s += 1 }
        return (p, s)
    }

    func applying(to document: CanvasDocument) throws -> CanvasDocument {
        var value = try JSONValue.of(document)
        for edit in edits { value = try Self.apply(edit.operation, path: edit.path[...], to: value) ?? .null }
        return try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(value))
    }
    /// The note's `assets` (as JSON) after this delta, given them before it, without building
    /// the note: edits elsewhere in the note are skipped. Nil when the delta has an edit of the
    /// note as a whole, or leaves no list of assets — it must then be applied to the whole note.
    func applying(toAssets assets: JSONValue) throws -> JSONValue? {
        var root = JSONValue.object(["assets": assets])
        for edit in edits {
            guard let first = edit.path.first else { return nil }
            guard case .key("assets") = first else { continue }
            guard let changed = try Self.apply(edit.operation, path: edit.path[...], to: root) else { return nil }
            root = changed
        }
        guard case .object(let object) = root, let result = object["assets"], case .array = result else { return nil }
        return result
    }

    /// The hashes of a list of assets as JSON (each asset's and its derivatives'). Nil when the
    /// value is not such a list.
    static func assetHashes(in assets: JSONValue) -> Set<String>? {
        guard case .array(let items) = assets else { return nil }
        var hashes: Set<String> = []
        for item in items {
            guard case .object(let asset) = item, case .string(let hash)? = asset["hash"] else { return nil }
            hashes.insert(hash)
            switch asset["derivatives"] {
            case .array(let derivatives)?:
                for derivative in derivatives {
                    guard case .object(let fields) = derivative, case .string(let hash)? = fields["hash"] else { return nil }
                    hashes.insert(hash)
                }
            case nil: break
            default: return nil
            }
        }
        return hashes
    }

    private static func apply(_ operation: Operation, path: ArraySlice<Component>, to value: JSONValue) throws -> JSONValue? {
        if let first = path.first {
            switch (first, value) {
            case (.key(let key), .object(var object)):
                object[key] = try apply(operation, path: path.dropFirst(), to: object[key] ?? .null)
                return .object(object)
            case (.index(let i), .array(var array)) where array.indices.contains(i):
                guard let changed = try apply(operation, path: path.dropFirst(), to: array[i]) else { throw PersistenceError.corruptData("Invalid delta index") }
                array[i] = changed; return .array(array)
            default: throw PersistenceError.corruptData("Invalid delta path")
            }
        }
        switch (operation, value) {
        case (.replace(let replacement), _): return replacement
        case (.text(let offset, let count, let insert), .string(let text)):
            var chars = Array(text)
            guard offset >= 0, count >= 0, offset <= chars.count, count <= chars.count - offset else { throw PersistenceError.corruptData("Invalid text delta") }
            chars.replaceSubrange(offset..<(offset + count), with: insert)
            return .string(String(chars))
        case (.array(let offset, let count, let insert), .array(var items)):
            guard offset >= 0, count >= 0, offset <= items.count, count <= items.count - offset else { throw PersistenceError.corruptData("Invalid array delta") }
            items.replaceSubrange(offset..<(offset + count), with: insert); return .array(items)
        default: throw PersistenceError.corruptData("Invalid delta operation")
        }
    }
}
