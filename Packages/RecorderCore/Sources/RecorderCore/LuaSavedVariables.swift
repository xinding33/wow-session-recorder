import Foundation

/// A value from a WoW SavedVariables file.
public indirect enum LuaValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case table([(key: LuaValue, value: LuaValue)])

    public static func == (lhs: LuaValue, rhs: LuaValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case let (.table(a), .table(b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { s } else { nil }
    }

    public var intValue: Int? {
        if case .number(let n) = self, n == n.rounded() { Int(n) } else { nil }
    }

    public var entries: [(key: LuaValue, value: LuaValue)] {
        if case .table(let entries) = self { entries } else { [] }
    }

    public subscript(key: String) -> LuaValue? {
        entries.first { $0.key == .string(key) }?.value
    }
}

/// Parses the subset of Lua that WoW writes to SavedVariables files:
/// `Name = { ["key"] = value, [1] = value, value, -- [2] }` with strings, numbers and booleans.
public enum LuaSavedVariables {
    public static func parse(_ text: String) -> [String: LuaValue] {
        var parser = Parser(Array(text.utf8))
        var result: [String: LuaValue] = [:]
        while true {
            parser.skipTrivia()
            guard let name = parser.identifier() else { break }
            parser.skipTrivia()
            guard parser.consume(UInt8(ascii: "=")) else { break }
            guard let value = parser.value() else { break }
            result[name] = value
        }
        return result
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var current: UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            i += 1
            return true
        }

        mutating func skipTrivia() {
            while let c = current {
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    i += 1
                } else if c == UInt8(ascii: "-"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "-") {
                    while let c = current, c != 0x0A { i += 1 }
                } else {
                    return
                }
            }
        }

        mutating func identifier() -> String? {
            func isLetter(_ c: UInt8) -> Bool { c == UInt8(ascii: "_") || (c | 0x20 >= 0x61 && c | 0x20 <= 0x7A) }
            guard let first = current, isLetter(first) else { return nil }
            let start = i
            while let c = current, isLetter(c) || (c >= 0x30 && c <= 0x39) {
                i += 1
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func value() -> LuaValue? {
            skipTrivia()
            guard let c = current else { return nil }
            switch c {
            case UInt8(ascii: "{"): return table()
            case UInt8(ascii: "\""): return string().map(LuaValue.string)
            default:
                if let word = identifier() {
                    switch word {
                    case "true": return .bool(true)
                    case "false": return .bool(false)
                    case "nil": return .bool(false)
                    default: return nil
                    }
                }
                return number()
            }
        }

        mutating func table() -> LuaValue? {
            guard consume(UInt8(ascii: "{")) else { return nil }
            var entries: [(key: LuaValue, value: LuaValue)] = []
            var nextIndex = 1.0
            while true {
                skipTrivia()
                if consume(UInt8(ascii: "}")) { return .table(entries) }
                var key: LuaValue
                if consume(UInt8(ascii: "[")) {
                    guard let k = value() else { return nil }
                    skipTrivia()
                    guard consume(UInt8(ascii: "]")) else { return nil }
                    skipTrivia()
                    guard consume(UInt8(ascii: "=")) else { return nil }
                    key = k
                } else {
                    // Array-style entry without an explicit key.
                    key = .number(nextIndex)
                    nextIndex += 1
                }
                guard let v = value() else { return nil }
                entries.append((key, v))
                skipTrivia()
                _ = consume(UInt8(ascii: ",")) || consume(UInt8(ascii: ";"))
            }
        }

        mutating func string() -> String? {
            guard consume(UInt8(ascii: "\"")) else { return nil }
            var out: [UInt8] = []
            while let c = current {
                i += 1
                if c == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                guard c == UInt8(ascii: "\\"), let e = current else { out.append(c); continue }
                i += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case 0x30...0x39:
                    // \ddd decimal byte escape.
                    var code = Int(e - 0x30)
                    for _ in 0..<2 {
                        guard let d = current, d >= 0x30, d <= 0x39 else { break }
                        code = code * 10 + Int(d - 0x30)
                        i += 1
                    }
                    out.append(UInt8(clamping: code))
                default: out.append(e)
                }
            }
            return nil
        }

        mutating func number() -> LuaValue? {
            let start = i
            while let c = current, (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
                    || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                i += 1
            }
            guard i > start, let n = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else { return nil }
            return .number(n)
        }
    }
}
