import Foundation
import Testing

@testable import SystemMCPCore

/// Both functions are pure over invented bytes and strings.
@Suite("Process arguments")
struct ProcessArgumentsTests {

    /// Builds a KERN_PROCARGS2 buffer: argc, the executable path, NUL padding, argv, then
    /// an environment that must never come out.
    private func buffer(
        argc: Int32? = nil, path: String = "/usr/bin/tool", arguments: [String],
        environment: [String] = ["SECRET_TOKEN=do-not-return", "HOME=/Users/user"], padding: Int = 3
    ) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc ?? Int32(arguments.count)) { Array($0) }
        bytes += Array(path.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        for variable in environment { bytes += Array(variable.utf8) + [0] }
        return bytes
    }

    @Test("Only argc arguments are returned and the environment is left alone")
    func parsesArgumentsNotEnvironment() {
        let parsed = ProcessArguments.parse(buffer(arguments: ["tool", "--flag", "value"]))
        #expect(parsed == ["tool", "--flag", "value"])
        #expect(parsed?.joined().contains("SECRET_TOKEN") == false)
    }

    @Test("A process with no arguments gives an empty list")
    func zeroArguments() {
        #expect(ProcessArguments.parse(buffer(argc: 0, arguments: [])) == [])
    }

    @Test("An argument that is empty is kept in its position")
    func emptyArgumentKeptInPlace() {
        // The empty string is a NUL straight after another NUL, which the padding skip
        // must not swallow once argv has started.
        #expect(ProcessArguments.parse(buffer(arguments: ["tool", "", "x"])) == ["tool", "", "x"])
    }

    @Test("A buffer cut short returns what it holds, and nonsense returns nothing")
    func malformedBuffers() {
        #expect(ProcessArguments.parse([]) == nil)
        #expect(ProcessArguments.parse([1, 0]) == nil)
        #expect(ProcessArguments.parse(buffer(argc: -4, arguments: ["a"])) == nil)
        #expect(ProcessArguments.parse(buffer(argc: 5000, arguments: ["a"])) == nil)
        // argc claims 3 but only 1 argument is present and no environment follows it.
        #expect(ProcessArguments.parse(buffer(argc: 3, arguments: ["only"], environment: [])) == ["only"])
    }

    @Test("A flag that names a secret masks the argument after it")
    func flagThenValue() {
        #expect(ProcessArguments.redact(["tool", "--token", "abc123", "--verbose"])
            == ["tool", "--token", "<redacted>", "--verbose"])
        #expect(ProcessArguments.redact(["--api-key", "k", "run"]) == ["--api-key", "<redacted>", "run"])
    }

    @Test("A secret flag followed by another flag does not swallow it")
    func secretFlagWithoutValue() {
        #expect(ProcessArguments.redact(["--password", "--verbose"]) == ["--password", "--verbose"])
    }

    @Test("key=value forms are masked whether or not they start with dashes")
    func keyValueForms() {
        #expect(ProcessArguments.redact(["--password=hunter2"]) == ["--password=<redacted>"])
        #expect(ProcessArguments.redact(["API_KEY=abc", "TOKEN=x"]) == ["API_KEY=<redacted>", "TOKEN=<redacted>"])
        #expect(ProcessArguments.redact(["--Auth-Token=abc"]) == ["--Auth-Token=<redacted>"])
    }

    @Test("Names are compared as whole words, including across camelCase and separators")
    func wordMatching() {
        #expect(ProcessArguments.words(in: "--apiKey") == ["api", "key"])
        #expect(ProcessArguments.words(in: "SECRET_ACCESS_KEY") == ["secret", "access", "key"])
        #expect(ProcessArguments.redact(["--apiKey=abc"]) == ["--apiKey=<redacted>"])
        #expect(ProcessArguments.redact(["--private-key", "/tmp/k"]) == ["--private-key", "<redacted>"])
        #expect(!ProcessArguments.looksSecret(name: "--author"))
        #expect(!ProcessArguments.looksSecret(name: "--keyboard-layout"))
        #expect(!ProcessArguments.looksSecret(name: "--key"))
    }

    @Test("Well-known credential prefixes are masked on their own")
    func credentialPrefixes() {
        let masked = ProcessArguments.redact(["ghp_abcdef123456", "github_pat_xyz", "sk-live-123", "AKIAEXAMPLE"])
        #expect(masked == Array(repeating: "<redacted>", count: 4))
    }

    @Test("A password inside a URL is masked and the user is kept")
    func urlCredentials() {
        #expect(ProcessArguments.redact(["https://user:hunter2@example.test/path"])
            == ["https://user:<redacted>@example.test/path"])
        #expect(ProcessArguments.redact(["--url=postgres://app:pw@db.test/x"])
            == ["--url=postgres://app:<redacted>@db.test/x"])
    }

    @Test("Ordinary arguments pass through untouched")
    func ordinaryArguments() {
        let ordinary = [
            "/usr/bin/tool", "--verbose", "-n", "5", "--path=/tmp/x", "https://example.test/a@b",
            "email@example.test", "--keyboard-layout", "us", "--author", "Someone", "--monkey", "x",
        ]
        #expect(ProcessArguments.redact(ordinary) == ordinary)
    }
}
