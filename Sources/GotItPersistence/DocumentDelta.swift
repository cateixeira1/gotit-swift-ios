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
        func value<T: Encodable>(_ value: T) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        }
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
        var value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(document))
        for edit in edits { value = try Self.apply(edit.operation, path: edit.path[...], to: value) ?? .null }
        return try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(value))
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
