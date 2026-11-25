import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool hands `notices` to `Format`, which puts them before the data.
public final class Arguments {
    private let values: [String: Value]

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    private func wholeNumber(_ name: String) throws -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return number
    }

    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A quantity: a size, a count, a wait. Outside its range it is moved to the nearest
    /// allowed value, and `notices` gains the sentence that says which value was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let number = try wholeNumber(name) else { return fallback }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// An identifier: a pid, a port. Outside its range it is refused, not moved, because
    /// the nearest allowed value would name something else than what was asked for.
    public func optionalIdentifier(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let number = try wholeNumber(name) else { return nil }
        guard range.contains(number) else {
            throw ToolError.badArgument(
                name: name,
                reason: "a whole number from \(range.lowerBound) to \(range.upperBound) was expected")
        }
        return number
    }

    public func requiredIdentifier(_ name: String, in range: ClosedRange<Int>) throws -> Int {
        guard let number = try optionalIdentifier(name, in: range) else {
            throw ToolError.missingArgument(name)
        }
        return number
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    public func bool(_ name: String, default fallback: Bool) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// One of a fixed set of words, compared case-insensitively.
    public func choice(_ name: String, among allowed: [String], default fallback: String) throws
        -> String
    {
        guard let raw = given(name) else { return fallback }
        let text = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty text is "not given", as it is for every other text argument.
        if text == "" { return fallback }
        guard let text, allowed.contains(text) else {
            throw ToolError.badArgument(
                name: name, reason: "expected one of: " + allowed.joined(separator: ", "))
        }
        return text
    }
}
