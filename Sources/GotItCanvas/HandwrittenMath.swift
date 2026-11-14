import Foundation
import GotItDomain

/// Math written with the pen: the text read from the writing is cleaned up (what handwriting
/// recognition confuses in formulas) and, when it is an arithmetic expression ending in "=" or an
/// equation in x up to the second degree, answered. Deterministic, never evaluates code.
public enum HandwrittenMath {

    /// The read text as a formula, or nil when it is not one (ordinary writing).
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("="), text.count <= 120 else { return nil }
        let replacements: [(String, String)] = [
            ("×", "*"), ("·", "*"), ("•", "*"), ("÷", "/"), (":", "/"), ("−", "-"), ("–", "-"), ("—", "-"),
            ("X", "x"), ("²", "^2"), (",", "."),
        ]
        for (from, to) in replacements { text = text.replacingOccurrences(of: from, with: to) }
        text = text.filter { !$0.isWhitespace }
        // Letters read in place of digits, only between digits or operators: O→0, l/I/|→1, S→5, B→8.
        let chars = Array(text)
        func isDigitLike(_ c: Character?) -> Bool { guard let c else { return true }; return c.isNumber || "+-*/=^().".contains(c) }
        var fixed = ""
        for (index, c) in chars.enumerated() {
            let before = index > 0 ? chars[index - 1] : nil, after = index + 1 < chars.count ? chars[index + 1] : nil
            let map: [Character: Character] = ["O": "0", "o": "0", "l": "1", "I": "1", "|": "1", "S": "5", "B": "8"]
            if let digit = map[c], isDigitLike(before), isDigitLike(after) { fixed.append(digit) } else { fixed.append(c) }
        }
        text = fixed
        // "x2" written as x² (the small 2 is read on the line): before an operator, "=" or the end.
        text = text.replacingOccurrences(of: #"x2(?=[+\-=*/)]|$)"#, with: "x^2", options: .regularExpression)
        let allowed = Set("0123456789.+-*/=^()x")
        guard text.allSatisfy(allowed.contains), text.contains(where: \.isNumber) else { return nil }
        guard text.filter({ $0 == "=" }).count == 1 else { return nil }
        return text
    }

    /// What to write after the formula: "19" for "12+7=", "x = 3" for an equation; nil when it
    /// cannot be answered (malformed, more than one unknown, degree above 2).
    public static func answer(_ formula: String) -> String? {
        let sides = formula.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
        guard sides.count == 2 else { return nil }
        if !formula.contains("x") {
            guard sides[1].isEmpty, let value = try? evaluate(sides[0]) else { return nil }
            return format(value)
        }
        guard !sides[1].isEmpty, let result = try? EquationSolver.solve(formula) else { return nil }
        switch result {
        case .realRoots(let roots): return roots.count == 1 ? "x = \(format(roots[0]))" : "x = \(format(roots[0])) ou x = \(format(roots[1]))"
        case .noRealRoots: return "sem solução real"
        case .allRealNumbers: return "todo x real"
        }
    }

    /// A number as people write it: up to 4 decimals, comma as decimal separator, minus sign.
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = (value * 10_000).rounded() / 10_000
        var text = rounded == rounded.rounded() && abs(rounded) < 1e15 ? String(Int64(rounded)) : String(format: "%.4f", rounded)
        if text.contains(".") { while text.hasSuffix("0") { text.removeLast() }; if text.hasSuffix(".") { text.removeLast() } }
        return text.replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−")
    }

    /// Arithmetic: + - * / ^ and parentheses, by precedence (recursive descent, no code evaluation).
    public static func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(chars: Array(expression))
        let value = try parser.sum()
        guard parser.index == parser.chars.count, value.isFinite else { throw DocumentError.invalid("Invalid arithmetic") }
        return value
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        mutating func sum() throws -> Double {
            var value = try product()
            while index < chars.count, chars[index] == "+" || chars[index] == "-" {
                let op = chars[index]; index += 1
                let rhs = try product(); value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }
        mutating func product() throws -> Double {
            var value = try power()
            while index < chars.count, chars[index] == "*" || chars[index] == "/" {
                let op = chars[index]; index += 1
                let rhs = try power()
                if op == "/" { guard rhs != 0 else { throw DocumentError.invalid("Division by zero") }; value /= rhs } else { value *= rhs }
            }
            return value
        }
        mutating func power() throws -> Double {
            let base = try unary()
            guard index < chars.count, chars[index] == "^" else { return base }
            index += 1
            let exponent = try power()
            guard abs(exponent) <= 64 else { throw DocumentError.invalid("Exponent too large") }
            return pow(base, exponent)
        }
        mutating func unary() throws -> Double {
            if index < chars.count, chars[index] == "-" { index += 1; return -(try unary()) }
            if index < chars.count, chars[index] == "+" { index += 1; return try unary() }
            return try atom()
        }
        mutating func atom() throws -> Double {
            guard index < chars.count else { throw DocumentError.invalid("Expression ends early") }
            if chars[index] == "(" {
                index += 1
                let value = try sum()
                guard index < chars.count, chars[index] == ")" else { throw DocumentError.invalid("Missing )") }
                index += 1
                return value
            }
            let start = index
            while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
            guard start < index, let value = Double(String(chars[start..<index])) else { throw DocumentError.invalid("Number expected") }
            return value
        }
    }
}
