import Foundation
import GotItDomain

public struct Polynomial: Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public init(a: Double, b: Double, c: Double) { self.a = a; self.b = b; self.c = c }
}

public enum EquationResult: Equatable, Sendable { case realRoots([Double]), noRealRoots, allRealNumbers }

/// A deterministic solver, independent of OCR. Never evaluates arbitrary code.
public enum EquationSolver {
    public static func parse(_ expression: String) throws -> Polynomial {
        guard expression.count <= 2_048 else { throw DocumentError.invalid("Expression too long") }
        let normalized = expression.lowercased().filter { !$0.isWhitespace }
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "²", with: "^2")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: ",", with: ".")
        let sides = normalized.split(separator: "=", omittingEmptySubsequences: false)
        guard sides.count == 2 else { throw DocumentError.invalid("Expected one equality") }
        let left = try terms(String(sides[0])), right = try terms(String(sides[1]))
        let result = Polynomial(a: left[2] - right[2], b: left[1] - right[1], c: left[0] - right[0])
        guard [result.a, result.b, result.c].allSatisfy(\.isFinite) else { throw DocumentError.invalid("Coefficients out of range") }
        return result
    }

    public static func solve(_ expression: String) throws -> EquationResult { try solve(parse(expression)) }

    public static func solve(_ p: Polynomial) throws -> EquationResult {
        guard [p.a, p.b, p.c].allSatisfy(\.isFinite) else { throw DocumentError.invalid("Nonfinite coefficient") }
        if p.a == 0 {
            if p.b == 0 { return p.c == 0 ? .allRealNumbers : .noRealRoots }
            let root = -p.c / p.b
            guard root.isFinite else { throw DocumentError.invalid("Root out of range") }
            return .realRoots([root])
        }
        if p.c == 0 {
            let other = -p.b / p.a
            guard other.isFinite else { throw DocumentError.invalid("Root out of range") }
            return .realRoots(other == 0 ? [0] : [0, other].sorted())
        }
        let scale = max(abs(p.a), abs(p.b), abs(p.c))
        let a = p.a / scale, b = p.b / scale, c = p.c / scale
        guard a != 0, c != 0, p.b == 0 || b != 0 else { throw DocumentError.invalid("Coefficient range exceeds precision") }
        let discriminant = b * b - 4 * a * c
        if discriminant < 0 { return .noRealRoots }
        if discriminant == 0 {
            let root = -b / (2 * a)
            guard root.isFinite else { throw DocumentError.invalid("Root out of range") }
            return .realRoots([root])
        }
        // Stable quadratic formula avoids cancellation of the smaller root.
        let q = -0.5 * (b + (b >= 0 ? 1.0 : -1.0) * sqrt(discriminant))
        let roots = [q / a, c / q].sorted()
        guard roots.allSatisfy(\.isFinite) else { throw DocumentError.invalid("Roots out of range") }
        return .realRoots(roots)
    }

    private static func terms(_ expression: String) throws -> [Double] {
        guard !expression.isEmpty else { throw DocumentError.invalid("Empty equation side") }
        let chars = Array(expression)
        var index = 0, coefficients = [Double](repeating: 0, count: 3)
        while index < chars.count {
            var sign = 1.0
            if chars[index] == "+" || chars[index] == "-" {
                sign = chars[index] == "-" ? -1 : 1; index += 1
            }
            let start = index
            while index < chars.count && chars[index] != "+" && chars[index] != "-" { index += 1 }
            guard start < index else { throw DocumentError.invalid("Empty term") }
            let term = String(chars[start..<index])
            let power: Int
            let coefficient: Double
            if let x = term.firstIndex(of: "x") {
                var prefix = String(term[..<x])
                guard prefix != "*" else { throw DocumentError.invalid("Missing coefficient") }
                if prefix.last == "*" { prefix.removeLast() }
                let suffix = String(term[term.index(after: x)...])
                switch suffix { case "", "^1": power = 1; case "^2": power = 2; case "^0": power = 0; default: throw DocumentError.invalid("Only degree 0, 1 or 2 is supported") }
                if prefix.isEmpty { coefficient = 1 }
                else { coefficient = try number(prefix) }
            } else { power = 0; coefficient = try number(term) }
            coefficients[power] += sign * coefficient
        }
        return coefficients
    }

    private static func number(_ text: String) throws -> Double {
        guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(text), value.isFinite else { throw DocumentError.invalid("Unsupported equation notation") }
        return value
    }
}
