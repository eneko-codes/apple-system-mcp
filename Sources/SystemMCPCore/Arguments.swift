import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
public struct Arguments {
    private let values: [String: Value]

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Clamps rather than rejects: a model asking for 5000 rows means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        if case .null = raw { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    public func optionalInt(_ name: String) throws -> Int? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return number
    }

    public func requiredInt(_ name: String) throws -> Int {
        guard let number = try optionalInt(name) else { throw ToolError.missingArgument(name) }
        return number
    }

    public func bool(_ name: String, default fallback: Bool) throws -> Bool {
        guard let raw = values[name] else { return fallback }
        if case .null = raw { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// One of a fixed set of words, compared case-insensitively.
    public func choice(_ name: String, among allowed: [String], default fallback: String) throws
        -> String
    {
        guard let text = optionalString(name)?.lowercased() else { return fallback }
        guard allowed.contains(text) else {
            throw ToolError.badArgument(
                name: name, reason: "expected one of: " + allowed.joined(separator: ", "))
        }
        return text
    }
}
