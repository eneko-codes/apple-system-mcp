import Foundation

/// Turns the raw `KERN_PROCARGS2` buffer into an argument list, and masks the arguments
/// that look like secrets. Pure functions over bytes, so both are tested with invented
/// data and no process.
public enum ProcessArguments {

    static let redacted = "<redacted>"

    /// Layout of the buffer: a native-endian `int` argc, the executable path and its NUL
    /// padding, then argc NUL-terminated arguments, and after those the environment.
    ///
    /// Only argc strings are returned. The environment is in the buffer but is never
    /// decoded, because it is where tokens and passwords usually live.
    public static func parse(_ buffer: [UInt8]) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count > headerSize else { return nil }
        let argumentCount = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount > 0, argumentCount < 4096 else { return argumentCount == 0 ? [] : nil }

        var index = headerSize
        // Executable path.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        // Padding NULs between the path and argv[0].
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        while arguments.count < Int(argumentCount), index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    // MARK: Redaction

    /// Whole words that mark a name as holding a secret. Compared as words, not as
    /// substrings, so `--author` and `--keyboard-layout` are not mistaken for `auth` and
    /// `key`.
    private static let secretWords: Set<String> = [
        "token", "tokens", "secret", "secrets", "password", "passwords", "passwd", "passphrase",
        "apikey", "credential", "credentials", "auth", "authorization", "bearer", "cookie",
    ]

    /// Pairs that only mean a secret together: `api-key`, `private_key`, `accessKey`.
    private static let secretPairs: Set<String> = ["api key", "private key", "access key", "ssh key"]

    /// Prefixes that identify well-known credential formats on their own.
    private static let credentialPrefixes = [
        "ghp_", "gho_", "ghs_", "ghu_", "github_pat_", "sk-", "xoxb-", "xoxp-", "AKIA", "AIza",
    ]

    static func looksSecret(name: String) -> Bool {
        let words = words(in: name)
        if words.contains(where: { secretWords.contains($0) }) { return true }
        return zip(words, words.dropFirst()).contains { secretPairs.contains("\($0) \($1)") }
    }

    /// Lowercase words, split on anything that is not a letter or digit and on camelCase
    /// boundaries: `--apiKey` and `API_KEY` both give `api`, `key`.
    static func words(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for character in name {
            if character.isLetter || character.isNumber {
                if character.isUppercase && previousWasLower, !current.isEmpty {
                    words.append(current.lowercased())
                    current = ""
                }
                current.append(character)
                previousWasLower = character.isLowercase
            } else {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// Best effort, never a guarantee: an unlabelled secret in an unusual position passes
    /// through. The tool documents that, and returns arguments only on request.
    public static func redact(_ arguments: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(arguments.count)
        var maskNext = false

        for argument in arguments {
            if maskNext {
                maskNext = false
                // A following flag means the previous one took no value.
                if !argument.hasPrefix("-") {
                    result.append(redacted)
                    continue
                }
            }

            if argument.hasPrefix("-") {
                if let equals = argument.firstIndex(of: "=") {
                    let name = String(argument[..<equals])
                    result.append(looksSecret(name: name) ? "\(name)=\(redacted)" : maskURLCredentials(argument))
                } else {
                    maskNext = looksSecret(name: argument)
                    result.append(argument)
                }
                continue
            }

            if let equals = argument.firstIndex(of: "="), looksSecret(name: String(argument[..<equals])) {
                result.append("\(argument[..<equals])=\(redacted)")
            } else if credentialPrefixes.contains(where: { argument.hasPrefix($0) }) {
                result.append(redacted)
            } else {
                result.append(maskURLCredentials(argument))
            }
        }
        return result
    }

    /// `scheme://user:password@host` keeps the user and loses the password.
    static func maskURLCredentials(_ text: String) -> String {
        guard let schemeEnd = text.range(of: "://") else { return text }
        let afterScheme = text[schemeEnd.upperBound...]
        guard let at = afterScheme.firstIndex(of: "@") else { return text }
        let authority = afterScheme[..<at]
        // A slash before the @ means the @ belongs to the path, not to userinfo.
        guard !authority.contains("/"), let colon = authority.firstIndex(of: ":") else { return text }
        return String(text[..<schemeEnd.upperBound]) + authority[..<colon] + ":" + redacted
            + afterScheme[at...]
    }
}
