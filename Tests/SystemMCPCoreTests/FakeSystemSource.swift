import Foundation
import MCP
import Synchronization

@testable import SystemMCPCore

/// An in-memory machine. Readings are scripted: each call to a snapshot method hands out
/// the next one in the queue and repeats the last, so a two-reading tool sees a "before"
/// and an "after" that the test chose. Every process, path and address in here is invented.
final class FakeSystemSource: SystemSource {

    struct State {
        var processSnapshots: [ProcessSnapshot] = []
        var details: [Int32: [ProcessDetail?]] = [:]
        var argumentsByPID: [Int32: [String]] = [:]
        var userNames: [UInt32: String] = [501: "user", 0: "root"]
        var coreTicks: [[CoreTicks]] = []
        var coreTicksError: Error?
        var kernelError: Error?
        var memory = FakeSystemSource.sampleMemory
        var pressure: MemoryPressure = .normal
        var swap = SwapUsage(totalBytes: 4 << 30, usedBytes: 1 << 30, isEncrypted: true)
        var hardware = HardwareInfo(
            chip: "Test Chip", logicalCores: 8, physicalCores: 8,
            coreGroups: [CoreGroup(name: "Performance", count: 4), CoreGroup(name: "Efficiency", count: 4)],
            memoryBytes: 16 << 30)
        var kernel = KernelInfo(
            osVersion: "99.0", build: "TEST1", bootTime: Date(timeIntervalSince1970: 1_000_000))
        var load: LoadAverage? = LoadAverage(oneMinute: 1.5, fiveMinutes: 2.5, fifteenMinutes: 3.5)
        var networkSnapshots: [NetworkSnapshot] = []
        var volumes: [Volume] = []
        var sockets: [SocketRecord] = []
        var clock: UInt64 = 0
    }

    let state = Mutex(State())
    /// How far the monotonic clock moves each time it is read.
    let tickNanoseconds: UInt64

    init(tickNanoseconds: UInt64 = 500_000_000, configure: (inout State) -> Void = { _ in }) {
        self.tickNanoseconds = tickNanoseconds
        state.withLock { configure(&$0) }
    }

    static let sampleMemory = MemorySnapshot(
        pageSize: 16384, totalBytes: 16 << 30, freePages: 5000, activePages: 20000,
        inactivePages: 10000, wiredPages: 100, compressedPages: 50, purgeablePages: 200,
        speculativePages: 1000, fileBackedPages: 3000, anonymousPages: 1000, swapIns: 7, swapOuts: 9)

    private static func next<Element>(_ queue: inout [Element]) -> Element? {
        guard let first = queue.first else { return nil }
        if queue.count > 1 { queue.removeFirst() }
        return first
    }

    // MARK: SystemSource

    func uptimeNanoseconds() -> UInt64 {
        state.withLock {
            let reading = $0.clock
            $0.clock += tickNanoseconds
            return reading
        }
    }

    func processSnapshot() throws -> ProcessSnapshot {
        state.withLock { Self.next(&$0.processSnapshots) }
            ?? ProcessSnapshot(takenAtNanoseconds: 0, records: [:])
    }

    func processDetail(pid: Int32) throws -> ProcessDetail? {
        state.withLock { state in
            guard var queue = state.details[pid] else { return nil }
            let reading = Self.next(&queue) ?? nil
            state.details[pid] = queue
            return reading
        }
    }

    func arguments(pid: Int32) throws -> [String]? {
        state.withLock { $0.argumentsByPID[pid] }
    }

    func userName(userID: UInt32) -> String? {
        state.withLock { $0.userNames[userID] }
    }

    func coreTicks() throws -> [CoreTicks] {
        try state.withLock { state in
            if let error = state.coreTicksError { throw error }
            return Self.next(&state.coreTicks) ?? []
        }
    }

    func memory() throws -> MemorySnapshot { state.withLock { $0.memory } }
    func memoryPressure() throws -> MemoryPressure { state.withLock { $0.pressure } }
    func swap() throws -> SwapUsage { state.withLock { $0.swap } }
    func hardware() throws -> HardwareInfo { state.withLock { $0.hardware } }

    func kernel() throws -> KernelInfo {
        try state.withLock {
            if let error = $0.kernelError { throw error }
            return $0.kernel
        }
    }

    func loadAverage() throws -> LoadAverage {
        try state.withLock {
            guard let load = $0.load else {
                throw SystemSourceError.callFailed(function: "getloadavg", code: 1)
            }
            return load
        }
    }

    func networkSnapshot() throws -> NetworkSnapshot {
        state.withLock { Self.next(&$0.networkSnapshots) }
            ?? NetworkSnapshot(takenAtNanoseconds: 0, interfaces: [])
    }

    func volumes() throws -> [Volume] { state.withLock { $0.volumes } }
    func sockets() throws -> [SocketRecord] { state.withLock { $0.sockets } }
}

// MARK: Builders for invented data

enum Sample {
    static func usage(
        cpuSeconds: Double, footprint: UInt64 = 100 << 20, threads: Int = 4
    ) -> ProcessUsage {
        ProcessUsage(
            cpuTimeNanoseconds: UInt64(cpuSeconds * 1e9), footprintBytes: footprint,
            residentBytes: footprint / 2, threadCount: threads, diskReadBytes: 2048,
            diskWrittenBytes: 4096)
    }

    static func record(
        pid: Int32, name: String, parent: Int32 = 1, user: UInt32 = 501, usage: ProcessUsage?
    ) -> ProcessRecord {
        ProcessRecord(
            identity: ProcessIdentity(
                pid: pid, parentPID: parent, userID: user, name: name,
                path: "/Applications/\(name).app/Contents/MacOS/\(name)", state: .sleeping),
            usage: usage)
    }

    static func snapshot(at nanoseconds: UInt64, _ records: [ProcessRecord]) -> ProcessSnapshot {
        ProcessSnapshot(
            takenAtNanoseconds: nanoseconds,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.identity.pid, $0) }))
    }

    static func volume(
        _ mountPoint: String, fileSystem: String = "apfs", total: UInt64 = 500 << 30,
        available: UInt64 = 100 << 30
    ) -> Volume {
        Volume(
            mountPoint: mountPoint, device: "/dev/disk-test", fileSystem: fileSystem,
            totalBytes: total, freeBytes: available, availableBytes: available,
            isReadOnly: false, isLocal: true)
    }

    static func socket(
        pid: Int32, _ transport: SocketProtocol = .tcp, port: Int, state: String? = "LISTEN",
        remote: Int = 0
    ) -> SocketRecord {
        SocketRecord(
            pid: pid, transport: transport, localAddress: "127.0.0.1", localPort: port,
            remoteAddress: remote == 0 ? "0.0.0.0" : "10.0.0.2", remotePort: remote, state: state)
    }
}

// MARK: Driving the tools

/// Records the waits the tools ask for instead of performing them.
final class SleepRecorder: Sendable {
    private let recorded = Mutex<[Int]>([])
    var milliseconds: [Int] { recorded.withLock { $0 } }
    func record(_ value: Int) { recorded.withLock { $0.append(value) } }
}

struct ToolResult {
    var text: String
    var isError: Bool
}

func call(
    _ tool: String, _ arguments: [String: Value] = [:], source: FakeSystemSource,
    sleeps: SleepRecorder = SleepRecorder()
) async -> ToolResult {
    let tools = SystemTools(
        source: source, sleep: { sleeps.record($0) }, now: { Date(timeIntervalSince1970: 1_000_000 + 90_000) })
    let result = await tools.handle(.init(name: tool, arguments: arguments))
    var text = ""
    for case .text(let part, _, _) in result.content { text += part }
    return ToolResult(text: text, isError: result.isError ?? false)
}
