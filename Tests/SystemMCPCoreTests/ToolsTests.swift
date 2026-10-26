import Foundation
import MCP
import Testing

@testable import SystemMCPCore

/// Every tool driven end to end against an invented machine. No kernel, no real process.
@Suite("Tools")
struct ToolsTests {

    /// Where each name first appears, so a test can assert the order of rows.
    private func order(_ names: [String], in text: String) -> [String] {
        names.compactMap { name in text.range(of: name).map { (name, $0.lowerBound) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func twoReadings(
        first: [ProcessRecord], second: [ProcessRecord], gap: UInt64 = 500_000_000
    ) -> FakeSystemSource {
        FakeSystemSource {
            $0.processSnapshots = [
                Sample.snapshot(at: 0, first), Sample.snapshot(at: gap, second),
            ]
        }
    }

    // MARK: Overview

    private func overviewSource() -> FakeSystemSource {
        FakeSystemSource {
            $0.coreTicks = [
                [CoreTicks(user: 100, system: 50, idle: 850, nice: 0), CoreTicks(user: 0, system: 0, idle: 1000, nice: 0)],
                [CoreTicks(user: 200, system: 100, idle: 1700, nice: 0), CoreTicks(user: 0, system: 0, idle: 2000, nice: 0)],
            ]
        }
    }

    @Test("The overview reports CPU as the tick delta across the sample, weighted over all cores")
    func overviewCPU() async {
        let sleeps = SleepRecorder()
        let result = await call("system_overview", source: overviewSource(), sleeps: sleeps)
        #expect(!result.isError)
        #expect(result.text.contains("7.5% (user 5.0% · system 2.5%)"))
        #expect(result.text.contains("92.5%"))
        #expect(result.text.contains("sampled over 500 ms"))
        #expect(sleeps.milliseconds == [500])
    }

    @Test("per_core adds one line per core")
    func overviewPerCore() async {
        let result = await call("system_overview", ["per_core": .bool(true)], source: overviewSource())
        #expect(result.text.contains("core  0  15.0%"))
        #expect(result.text.contains("core  1  0.0%"))
    }

    @Test("sample_ms is clamped to the advertised range")
    func sampleIsClamped() async {
        let high = SleepRecorder()
        _ = await call("system_overview", ["sample_ms": .int(99_999)], source: overviewSource(), sleeps: high)
        #expect(high.milliseconds == [ToolCatalog.sampleRange.upperBound])
        let low = SleepRecorder()
        _ = await call("system_overview", ["sample_ms": .int(1)], source: overviewSource(), sleeps: low)
        #expect(low.milliseconds == [ToolCatalog.sampleRange.lowerBound])
    }

    @Test("The overview names the machine, the memory approximation and the pressure")
    func overviewContent() async {
        let result = await call("system_overview", source: overviewSource())
        #expect(result.text.contains("macOS 99.0 (TEST1) · up 1d 1h"))
        #expect(result.text.contains("Test Chip"))
        #expect(result.text.contains("8 cores (4 Performance + 4 Efficiency)"))
        #expect(result.text.contains("an approximation"))
        #expect(result.text.contains("pressure"))
        #expect(result.text.contains("normal"))
        #expect(result.text.contains("1.0 GB used of 4.0 GB, encrypted"))
        #expect(result.text.contains(Format.bytes(FakeSystemSource.sampleMemory.usedBytes)))
    }

    @Test("A failing extra leaves the rest of the overview intact")
    func overviewSurvivesMissingLoad() async {
        let source = overviewSource()
        source.state.withLock { $0.load = nil }
        let result = await call("system_overview", source: source)
        #expect(!result.isError)
        #expect(!result.text.contains("load average"))
        #expect(result.text.contains("Memory"))
    }

    @Test("A failing essential call is reported with its function and code")
    func overviewReportsFailure() async {
        let source = overviewSource()
        source.state.withLock {
            $0.coreTicksError = SystemSourceError.callFailed(function: "host_processor_info", code: 5)
        }
        let result = await call("system_overview", source: source)
        #expect(result.isError)
        #expect(result.text.contains("host_processor_info"))
        #expect(result.text.contains("5"))
    }

    private struct LeakyError: LocalizedError {
        var errorDescription: String? { "could not open /Users/user/secret-project/notes.txt" }
    }

    @Test("An error the server does not own never has its description shown")
    func foreignErrorDescriptionDoesNotLeak() async {
        let source = overviewSource()
        source.state.withLock { $0.kernelError = LeakyError() }
        let result = await call("system_overview", source: source)
        #expect(result.isError)
        #expect(!result.text.contains("secret-project"))
        #expect(!result.text.contains("/Users"))
    }

    // MARK: Process list

    private let alphaBefore = Sample.record(pid: 10, name: "alpha", usage: Sample.usage(cpuSeconds: 1.0, footprint: 300 << 20, threads: 10))
    private let betaBefore = Sample.record(pid: 20, name: "beta", usage: Sample.usage(cpuSeconds: 0.0, footprint: 900 << 20))
    private let gamma = Sample.record(pid: 30, name: "gamma", user: 0, usage: nil)

    private func listing() -> FakeSystemSource {
        twoReadings(
            first: [alphaBefore, betaBefore, gamma],
            second: [
                Sample.record(pid: 10, name: "alpha", usage: Sample.usage(cpuSeconds: 1.5, footprint: 300 << 20, threads: 10)),
                Sample.record(pid: 20, name: "beta", parent: 10, usage: Sample.usage(cpuSeconds: 0.25, footprint: 900 << 20)),
                gamma,
            ])
    }

    @Test("Processes default to CPU descending, with unreadable rows last and shown as n/a")
    func processesByCPU() async {
        let result = await call("system_processes", source: listing())
        #expect(!result.isError)
        #expect(order(["alpha", "beta", "gamma"], in: result.text) == ["alpha", "beta", "gamma"])
        #expect(result.text.contains("100.0"))
        #expect(result.text.contains("50.0"))
        #expect(result.text.contains("3 visible"))
        #expect(result.text.contains("readable for 2"))
        #expect(result.text.contains("The other 1 belong to other users"))
        #expect(result.text.contains("n/a"))
    }

    @Test("Sorting by memory puts the biggest first and unreadable last")
    func processesByMemory() async {
        let result = await call("system_processes", ["sort_by": .string("memory")], source: listing())
        #expect(order(["alpha", "beta", "gamma"], in: result.text) == ["beta", "alpha", "gamma"])
    }

    @Test("Sorting by name and by pid is ascending")
    func processesByNameAndPID() async {
        let byName = await call("system_processes", ["sort_by": .string("name")], source: listing())
        #expect(order(["alpha", "beta", "gamma"], in: byName.text) == ["alpha", "beta", "gamma"])
        let byPID = await call("system_processes", ["sort_by": .string("pid")], source: listing())
        #expect(order(["alpha", "beta", "gamma"], in: byPID.text) == ["alpha", "beta", "gamma"])
    }

    @Test("Filters by name, user and parent each narrow the list")
    func processFilters() async {
        let byName = await call("system_processes", ["name_contains": .string("ALP")], source: listing())
        #expect(byName.text.contains("alpha") && !byName.text.contains("beta"))
        #expect(byName.text.contains("Showing 1 of 1 matching"))

        let byUser = await call("system_processes", ["user": .string("root")], source: listing())
        #expect(byUser.text.contains("gamma") && !byUser.text.contains("alpha"))

        let byUID = await call("system_processes", ["user": .string("501")], source: listing())
        #expect(byUID.text.contains("alpha") && byUID.text.contains("beta") && !byUID.text.contains("gamma"))

        let byParent = await call("system_processes", ["parent_pid": .int(10)], source: listing())
        #expect(byParent.text.contains("beta") && !byParent.text.contains("alpha"))
    }

    @Test("limit caps the rows and the header still reports how many matched")
    func processLimit() async {
        let result = await call("system_processes", ["limit": .int(2)], source: listing())
        #expect(result.text.contains("Showing 2 of 3 matching"))
        #expect(!result.text.contains("gamma"))
    }

    @Test("A process absent from the first reading, or whose counter went backwards, has no CPU rate")
    func newAndRecycledProcessesHaveNoRate() async {
        let source = twoReadings(
            first: [Sample.record(pid: 50, name: "recycled", usage: Sample.usage(cpuSeconds: 5))],
            second: [
                Sample.record(pid: 50, name: "recycled", usage: Sample.usage(cpuSeconds: 1)),
                Sample.record(pid: 40, name: "newcomer", usage: Sample.usage(cpuSeconds: 2)),
            ])
        let result = await call("system_processes", source: source)
        let rows = result.text.split(separator: "\n").filter { $0.contains("recycled") || $0.contains("newcomer") }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.contains("n/a") })
    }

    @Test("An unknown sort key is refused and the answer lists the valid ones")
    func badSortKey() async {
        let result = await call("system_processes", ["sort_by": .string("banana")], source: listing())
        #expect(result.isError)
        #expect(result.text.contains("expected one of: cpu, memory, name, pid"))
    }

    @Test("The CPU % header says it is of one core")
    func processHeaderExplainsUnits() async {
        let result = await call("system_processes", source: listing())
        #expect(result.text.contains("of one core"))
    }

    // MARK: One process

    private func detail(
        cpu: Double, usage: Bool = true, children: [Int32] = [11, 12]
    ) -> ProcessDetail {
        ProcessDetail(
            record: Sample.record(pid: 10, name: "alpha", usage: usage ? Sample.usage(cpuSeconds: cpu) : nil),
            startTime: Date(timeIntervalSince1970: 1_000_000 + 90_000 - 3600),
            workingDirectory: "/tmp/work", childPIDs: children, openDescriptorCount: 7)
    }

    private func processSource(second: ProcessDetail?? = nil, usage: Bool = true) -> FakeSystemSource {
        FakeSystemSource {
            let secondReading: ProcessDetail? = second ?? Optional(detail(cpu: 1.5, usage: usage))
            $0.details[10] = [detail(cpu: 1.0, usage: usage), secondReading]
            $0.details[1] = [ProcessDetail(record: Sample.record(pid: 1, name: "launchd", parent: 0, user: 0, usage: nil))]
            $0.details[11] = [ProcessDetail(record: Sample.record(pid: 11, name: "child-a", parent: 10, usage: nil))]
            $0.details[12] = [ProcessDetail(record: Sample.record(pid: 12, name: "child-b", parent: 10, usage: nil))]
            $0.argumentsByPID[10] = ["/Applications/alpha", "--token", "hunter2", "--verbose"]
        }
    }

    @Test("One process: identity, CPU rate over the sample, memory, parent, children and directory")
    func processDetailContent() async {
        let result = await call("system_process", ["pid": .int(10)], source: processSource())
        #expect(!result.isError)
        #expect(result.text.contains("Process 10 — alpha"))
        #expect(result.text.contains("100.0% of one core over 500 ms"))
        #expect(result.text.contains("1 (launchd)"))
        #expect(result.text.contains("11 (child-a), 12 (child-b)"))
        #expect(result.text.contains("/tmp/work"))
        #expect(result.text.contains("7 open"))
        #expect(result.text.contains("(1h 0m ago)"))
        #expect(result.text.contains("user (uid 501)"))
    }

    @Test("Arguments are withheld unless asked for, and masked when they are")
    func argumentsAreOptInAndMasked() async {
        let withheld = await call("system_process", ["pid": .int(10)], source: processSource())
        #expect(!withheld.text.contains("hunter2"))
        #expect(!withheld.text.contains("--verbose"))
        #expect(!withheld.text.contains("Arguments"))

        let requested = await call(
            "system_process", ["pid": .int(10), "include_arguments": .bool(true)], source: processSource())
        #expect(!requested.text.contains("hunter2"))
        #expect(requested.text.contains("<redacted>"))
        #expect(requested.text.contains("--verbose"))
        #expect(requested.text.contains("environment is never read"))
    }

    @Test("Arguments that cannot be read say so instead of showing an empty list")
    func unreadableArguments() async {
        let source = processSource()
        source.state.withLock { $0.argumentsByPID[10] = nil }
        let result = await call(
            "system_process", ["pid": .int(10), "include_arguments": .bool(true)], source: source)
        #expect(result.text.contains("not readable"))
    }

    @Test("A process that is not readable still shows its identity and says why usage is missing")
    func unreadableProcess() async {
        let result = await call("system_process", ["pid": .int(10)], source: processSource(usage: false))
        #expect(!result.isError)
        #expect(result.text.contains("Process 10 — alpha"))
        #expect(result.text.contains("not readable"))
        #expect(!result.text.contains("of one core over"))
    }

    @Test("A process that exits during the sample is reported, not treated as an error")
    func processExitsDuringSample() async {
        let result = await call("system_process", ["pid": .int(10)], source: processSource(second: .some(nil)))
        #expect(!result.isError)
        #expect(result.text.contains("exited during"))
    }

    @Test("A pid that does not exist is an error that says pids go stale")
    func missingProcess() async {
        let result = await call("system_process", ["pid": .int(999)], source: processSource())
        #expect(result.isError)
        #expect(result.text.contains("No process with pid 999"))
        #expect(result.text.contains("stale"))
    }

    @Test("pid is required")
    func pidRequired() async {
        let result = await call("system_process", source: processSource())
        #expect(result.isError)
        #expect(result.text.contains("Missing required argument 'pid'"))
    }

    // MARK: Network

    private func networkSource(second: UInt64 = 3000, sentSecond: UInt64 = 500) -> FakeSystemSource {
        func interfaces(received: UInt64, sent: UInt64) -> [NetworkInterface] {
            [
                NetworkInterface(name: "en0", isUp: true, isLoopback: false, addresses: ["192.168.0.2"], receivedBytes: received, sentBytes: sent),
                NetworkInterface(name: "lo0", isUp: true, isLoopback: true, addresses: ["127.0.0.1"], receivedBytes: 0, sentBytes: 0),
                NetworkInterface(name: "utun3", isUp: false, isLoopback: false, addresses: [], receivedBytes: 0, sentBytes: 0),
                NetworkInterface(name: "awdl0", isUp: true, isLoopback: false, addresses: [], receivedBytes: 0, sentBytes: 0),
            ]
        }
        return FakeSystemSource {
            $0.networkSnapshots = [
                NetworkSnapshot(takenAtNanoseconds: 0, interfaces: interfaces(received: 1000, sent: 500)),
                NetworkSnapshot(takenAtNanoseconds: 1_000_000_000, interfaces: interfaces(received: second, sent: sentSecond)),
            ]
        }
    }

    @Test("Network rates are the byte delta over the elapsed time")
    func networkRates() async {
        let result = await call("system_network", source: networkSource())
        #expect(!result.isError)
        #expect(result.text.contains("192.168.0.2"))
        #expect(result.text.contains(Format.bytesPerSecond(2000)))
        #expect(result.text.contains("0 B/s"))
        #expect(result.text.contains("rates are over 1000 ms"))
    }

    @Test("Down or idle interfaces are hidden and counted, and shown on request")
    func networkHidesInactive() async {
        let hidden = await call("system_network", source: networkSource())
        #expect(!hidden.text.contains("utun3") && !hidden.text.contains("awdl0"))
        #expect(hidden.text.contains("2 down or idle hidden"))
        #expect(hidden.text.contains("lo0"))

        let shown = await call("system_network", ["include_inactive": .bool(true)], source: networkSource())
        #expect(shown.text.contains("utun3") && shown.text.contains("awdl0"))
    }

    @Test("sample_ms 0 returns totals only and does not wait")
    func networkWithoutSample() async {
        let sleeps = SleepRecorder()
        let result = await call("system_network", ["sample_ms": .int(0)], source: networkSource(), sleeps: sleeps)
        #expect(sleeps.milliseconds.isEmpty)
        #expect(!result.text.contains("rates are over"))
        #expect(!result.text.contains("B/s"))
    }

    @Test("A counter that went backwards has no rate")
    func networkCounterReset() async {
        let result = await call("system_network", source: networkSource(second: 3000, sentSecond: 100))
        #expect(result.text.contains("n/a"))
    }

    // MARK: Volumes

    @Test("System-internal volumes are hidden by default and the data volume stays")
    func volumesHideSystemOnes() async {
        let source = FakeSystemSource {
            $0.volumes = [
                Sample.volume("/"), Sample.volume("/System/Volumes/Data"),
                Sample.volume("/System/Volumes/VM"), Sample.volume("/dev", fileSystem: "devfs"),
                Sample.volume("/Volumes/External", fileSystem: "exfat"),
                Sample.volume("/private/var/folders/xx/T/AppTranslocation/ABC", fileSystem: "nullfs"),
                Sample.volume("/Users/user/Library/DeviceFS", fileSystem: "devicefs"),
            ]
        }
        let defaults = await call("system_volumes", source: source)
        #expect(defaults.text.contains("/System/Volumes/Data"))
        #expect(defaults.text.contains("/Volumes/External"))
        #expect(!defaults.text.contains("/System/Volumes/VM"))
        #expect(!defaults.text.contains("devfs"))
        #expect(!defaults.text.contains("nullfs") && !defaults.text.contains("devicefs"))
        #expect(defaults.text.contains("4 system volumes hidden"))

        let all = await call("system_volumes", ["include_hidden": .bool(true)], source: source)
        #expect(all.text.contains("/System/Volumes/VM"))
        #expect(all.text.contains("devfs"))
        #expect(all.text.contains("nullfs") && all.text.contains("devicefs"))
    }

    @Test("Volume capacity shows total and the share an ordinary process may use")
    func volumeCapacity() async {
        let source = FakeSystemSource {
            $0.volumes = [Sample.volume("/", total: 400 << 30, available: 100 << 30)]
        }
        let result = await call("system_volumes", source: source)
        #expect(result.text.contains("400 GB total"))
        #expect(result.text.contains("100 GB available (25%)"))
    }

    // MARK: Connections

    private func socketSource() -> FakeSystemSource {
        FakeSystemSource {
            $0.processSnapshots = [
                Sample.snapshot(at: 0, [
                    Sample.record(pid: 10, name: "alpha", usage: Sample.usage(cpuSeconds: 1)),
                    Sample.record(pid: 20, name: "beta", user: 0, usage: nil),
                ])
            ]
            $0.sockets = [
                Sample.socket(pid: 10, port: 3000),
                Sample.socket(pid: 10, port: 52000, state: "ESTABLISHED", remote: 443),
                Sample.socket(pid: 20, .udp, port: 5353, state: nil),
                Sample.socket(pid: 20, .udp, port: 0, state: nil),
                Sample.socket(pid: 99, port: 8080),
            ]
        }
    }

    @Test("By default only sockets waiting for traffic are listed, in port order, with the owner's name")
    func connectionsDefault() async {
        let result = await call("system_connections", source: socketSource())
        #expect(!result.isError)
        #expect(order(["3000", "5353", "8080"], in: result.text) == ["3000", "5353", "8080"])
        #expect(!result.text.contains("52000"))
        #expect(result.text.contains("alpha") && result.text.contains("beta"))
        #expect(result.text.contains("(exited)"))
        // The unbound UDP socket is not waiting for anything and is not listed.
        #expect(result.text.contains("3 matching, from 1 of 2 processes"))
        #expect(result.text.contains("not visible without root"))
    }

    @Test("Connection filters: state, port, protocol and pid")
    func connectionFilters() async {
        let established = await call("system_connections", ["state": .string("established")], source: socketSource())
        #expect(established.text.contains("52000") && !established.text.contains("3000"))

        let byRemotePort = await call("system_connections", ["state": .string("all"), "port": .int(443)], source: socketSource())
        #expect(byRemotePort.text.contains("52000") && !byRemotePort.text.contains("5353"))

        let udp = await call("system_connections", ["state": .string("all"), "protocol": .string("udp")], source: socketSource())
        #expect(udp.text.contains("5353") && !udp.text.contains("3000"))

        let byPID = await call("system_connections", ["state": .string("all"), "pid": .int(10)], source: socketSource())
        #expect(byPID.text.contains("3000") && byPID.text.contains("52000") && !byPID.text.contains("5353"))
    }

    @Test("An unknown state is refused")
    func badConnectionState() async {
        let result = await call("system_connections", ["state": .string("open")], source: socketSource())
        #expect(result.isError)
    }

    // MARK: Status and routing

    @Test("Status reports how many processes are visible and how many are readable")
    func statusCounts() async {
        let source = FakeSystemSource {
            $0.processSnapshots = [
                Sample.snapshot(at: 0, [
                    Sample.record(pid: 10, name: "alpha", usage: Sample.usage(cpuSeconds: 1)),
                    Sample.record(pid: 20, name: "beta", usage: nil),
                ])
            ]
        }
        let result = await call("system_status", source: source)
        #expect(!result.isError)
        #expect(result.text.contains("ready"))
        #expect(result.text.contains("2 visible"))
        #expect(result.text.contains("1 with CPU and memory counters"))
        #expect(result.text.contains("99.0"))
        #expect(result.text.contains("reads no file contents"))
    }

    @Test("A name that is not a tool of this server is refused")
    func unknownTool() async {
        let result = await call("system_reboot", source: FakeSystemSource())
        #expect(result.isError)
        #expect(result.text.contains("not a tool of this server"))
    }
}
