import Foundation
import Testing

@testable import SystemMCPCore

@Suite("Metrics")
struct MetricsTests {

    @Test("CPU shares are the tick delta of each state over the total delta")
    func cpuShares() throws {
        let breakdown = try #require(
            Metrics.cpuBreakdown(
                from: CoreTicks(user: 100, system: 50, idle: 850, nice: 0),
                to: CoreTicks(user: 200, system: 100, idle: 1700, nice: 0)))
        #expect(abs(breakdown.userPercent - 10) < 1e-9)
        #expect(abs(breakdown.systemPercent - 5) < 1e-9)
        #expect(abs(breakdown.idlePercent - 85) < 1e-9)
        #expect(abs(breakdown.busyPercent - 15) < 1e-9)
    }

    @Test("Nice ticks count as user time")
    func niceIsUser() throws {
        let breakdown = try #require(
            Metrics.cpuBreakdown(
                from: CoreTicks(user: 0, system: 0, idle: 0, nice: 0),
                to: CoreTicks(user: 10, system: 0, idle: 80, nice: 10)))
        #expect(abs(breakdown.userPercent - 20) < 1e-9)
    }

    @Test("A 32-bit tick counter that wrapped between readings still gives the right delta")
    func tickCounterWraps() throws {
        let nearTheTop: UInt64 = (1 << 32) - 100
        let breakdown = try #require(
            Metrics.cpuBreakdown(
                from: CoreTicks(user: nearTheTop, system: 0, idle: 0, nice: 0),
                to: CoreTicks(user: 100, system: 0, idle: 200, nice: 0)))
        // 200 user ticks (100 up to the wrap, 100 after) against 200 idle ticks.
        #expect(abs(breakdown.userPercent - 50) < 1e-9)
    }

    @Test("Every core is differenced on its own before the cores are added")
    func coresAreDifferencedSeparately() throws {
        let wrappedCore = CoreTicks(user: (1 << 32) - 50, system: 0, idle: 0, nice: 0)
        let quietCore = CoreTicks(user: 0, system: 0, idle: 1000, nice: 0)
        let breakdown = try #require(
            Metrics.cpuBreakdown(
                from: [wrappedCore, quietCore],
                to: [CoreTicks(user: 50, system: 0, idle: 0, nice: 0), CoreTicks(user: 0, system: 0, idle: 2000, nice: 0)]))
        // Core 0 used 100 user ticks; core 1 idled for 1000.
        #expect(abs(breakdown.userPercent - 100.0 / 1100.0 * 100) < 1e-9)
    }

    @Test("No elapsed ticks, or a different number of cores, gives no answer instead of a division by zero")
    func degenerateCPUReadings() {
        let same = CoreTicks(user: 5, system: 5, idle: 5, nice: 0)
        #expect(Metrics.cpuBreakdown(from: same, to: same) == nil)
        #expect(Metrics.cpuBreakdown(from: [same], to: [same, same]) == nil)
        #expect(Metrics.cpuBreakdown(from: [], to: []) == nil)
    }

    @Test("Process CPU is CPU time over wall time, as a percentage of one core")
    func processCPU() {
        let before = Sample.usage(cpuSeconds: 1.0)
        #expect(Metrics.processCPUPercent(before: before, after: Sample.usage(cpuSeconds: 1.5), elapsedNanoseconds: 500_000_000) == 100)
        // Two cores busy for the whole interval.
        #expect(Metrics.processCPUPercent(before: before, after: Sample.usage(cpuSeconds: 2.0), elapsedNanoseconds: 500_000_000) == 200)
    }

    @Test("Process CPU is unavailable when a reading is missing, the counter went backwards, or no time passed")
    func processCPUUnavailable() {
        let usage = Sample.usage(cpuSeconds: 2)
        #expect(Metrics.processCPUPercent(before: nil, after: usage, elapsedNanoseconds: 1) == nil)
        #expect(Metrics.processCPUPercent(before: usage, after: nil, elapsedNanoseconds: 1) == nil)
        #expect(Metrics.processCPUPercent(before: usage, after: Sample.usage(cpuSeconds: 1), elapsedNanoseconds: 1) == nil)
        #expect(Metrics.processCPUPercent(before: usage, after: usage, elapsedNanoseconds: 0) == nil)
    }

    @Test("A byte rate is the delta over the elapsed seconds, and a reset gives none")
    func byteRate() {
        #expect(Metrics.bytesPerSecond(before: 1000, after: 3000, elapsedNanoseconds: 1_000_000_000) == 2000)
        #expect(Metrics.bytesPerSecond(before: 0, after: 1000, elapsedNanoseconds: 500_000_000) == 2000)
        #expect(Metrics.bytesPerSecond(before: 3000, after: 1000, elapsedNanoseconds: 1_000_000_000) == nil)
        #expect(Metrics.bytesPerSecond(before: 0, after: 1, elapsedNanoseconds: 0) == nil)
    }

    @Test("Memory in use never underflows when purgeable pages exceed anonymous ones")
    func memoryArithmeticIsSafe() {
        var memory = FakeSystemSource.sampleMemory
        memory.purgeablePages = memory.anonymousPages + 500
        memory.speculativePages = memory.freePages + 500
        #expect(memory.usedBytes == (memory.wiredPages + memory.compressedPages) * memory.pageSize)
        #expect(memory.freeBytes == 0)
    }

    @Test("Memory in use is app memory plus wired plus compressed, in bytes")
    func memoryInUse() {
        // anonymous 1000 - purgeable 200 = 800 app pages; + 100 wired + 50 compressed.
        #expect(FakeSystemSource.sampleMemory.usedBytes == 950 * 16384)
        // 5000 free, of which 1000 are speculative and reported apart.
        #expect(FakeSystemSource.sampleMemory.freeBytes == 4000 * 16384)
    }

    @Test("Memory pressure maps the kernel's values to words")
    func pressureLabels() {
        #expect(MemoryPressure(rawValue: 1).label == "normal")
        #expect(MemoryPressure(rawValue: 2).label == "warning")
        #expect(MemoryPressure(rawValue: 4).label == "critical")
        #expect(MemoryPressure(rawValue: 3).label == "unknown (3)")
    }

    @Test("Socket listening means TCP LISTEN or a bound UDP socket with no peer")
    func listeningSockets() {
        #expect(Sample.socket(pid: 1, port: 80).isListening)
        #expect(!Sample.socket(pid: 1, port: 80, state: "ESTABLISHED", remote: 443).isListening)
        #expect(Sample.socket(pid: 1, .udp, port: 53, state: nil).isListening)
        #expect(!Sample.socket(pid: 1, .udp, port: 53, state: nil, remote: 53).isListening)
        // Created but never bound: no port, so nothing can reach it.
        #expect(!Sample.socket(pid: 1, .udp, port: 0, state: nil).isListening)
    }
}
