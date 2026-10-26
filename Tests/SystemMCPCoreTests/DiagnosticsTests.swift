import Foundation
import Testing

@testable import SystemMCPCore

@Suite("Diagnostics")
struct DiagnosticsTests {

    private enum SampleError: Error {
        case notFound(identifier: String)
        case plain
    }

    @Test("An enum error is reported by case, never by its payload")
    func enumPayloadStaysOut() {
        let kind = Diagnostics.kind(of: SampleError.notFound(identifier: "/Users/user/secret.txt"))
        #expect(kind.hasSuffix("SampleError.notFound"))
        #expect(!kind.contains("secret"))
        #expect(!kind.contains("/Users"))
        #expect(Diagnostics.kind(of: SampleError.plain).hasSuffix("SampleError.plain"))
    }

    @Test("The server's own errors are reported by case only")
    func ownErrorsAreReducedToTheirCase() {
        #expect(Diagnostics.kind(of: ToolError.processNotFound(pid: 4242)).hasSuffix("ToolError.processNotFound"))
        #expect(!Diagnostics.kind(of: ToolError.processNotFound(pid: 4242)).contains("4242"))
        let failure = Diagnostics.kind(of: SystemSourceError.callFailed(function: "proc_pidinfo", code: 1))
        #expect(failure.hasSuffix("SystemSourceError.callFailed"))
        #expect(!failure.contains("proc_pidinfo"))
    }

    @Test("A non-enum error is reduced to domain and code, dropping its description")
    func foundationErrorHasNoDescription() {
        let error = NSError(
            domain: "TestDomain", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "could not open /Users/user/private.pdf"])
        #expect(Diagnostics.kind(of: error) == "TestDomain#7")
    }

    @Test("A tool name that is not a plain identifier cannot reach the log")
    func toolNameIsSanitised() {
        #expect(Diagnostics.toolName("system_processes") == "system_processes")
        #expect(Diagnostics.toolName("evil\nfatal forged line") == "invalid")
        #expect(Diagnostics.toolName("") == "invalid")
        #expect(Diagnostics.toolName(String(repeating: "a", count: 65)) == "invalid")
    }

    @Test("Every line names the process that wrote it, so two instances can be told apart")
    func lineCarriesProcessID() {
        let first = Diagnostics.line("info", "started", processID: 4242)
        let second = Diagnostics.line("info", "started", processID: 4243)
        #expect(first.contains("[4242] started"))
        #expect(first != second)
    }
}
