import Dispatch
import Foundation
import Testing

@testable import SystemMCPCore

/// A call that never finishes must still be answered. Both ways it can stay stuck are
/// covered: an `await` that never resumes, and a synchronous system call that never
/// returns and so holds its thread.
@Suite("Timeout")
struct TimeoutTests {

    private let shortTimeout = Duration.milliseconds(200)

    @Test("A wait that never ends is answered with a clear time-out error", .timeLimit(.minutes(1)))
    func hungSleepIsAnswered() async {
        let result = await call(
            "system_processes", ["name_contains": .string("alpha")], source: FakeSystemSource(),
            sleep: { _ in await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } },
            timeout: shortTimeout)
        #expect(result.isError)
        #expect(result.text.contains("did not finish"))
        #expect(result.text.contains("nothing was changed"))
    }

    @Test("A system call that blocks its thread is answered too", .timeLimit(.minutes(1)))
    func blockedSystemCallIsAnswered() async {
        let gate = DispatchSemaphore(value: 0)
        let source = FakeSystemSource { $0.blockProcessSnapshot = gate }
        // Released afterwards so the abandoned work does not leak a blocked thread.
        defer { gate.signal(); gate.signal() }

        let result = await call(
            "system_processes", ["name_contains": .string("virtualization")], source: source,
            timeout: shortTimeout)
        #expect(result.isError)
        #expect(result.text.contains("did not finish"))
    }

    @Test("A call that finishes in time is untouched by the deadline")
    func fastCallIsUnaffected() async {
        let result = await call("system_status", source: FakeSystemSource(), timeout: shortTimeout)
        #expect(!result.isError)
        #expect(result.text.contains("ready"))
    }

    @Test("The time-out error states the limit in seconds")
    func messageStatesLimit() {
        #expect(ToolError.timedOut(seconds: 30).message.contains("30 seconds"))
    }

    @Test("A time-out is logged as a kind, never with a payload")
    func kindCarriesNoPayload() {
        #expect(Diagnostics.kind(of: ToolError.timedOut(seconds: 30)) == "ToolError.timedOut")
    }
}
