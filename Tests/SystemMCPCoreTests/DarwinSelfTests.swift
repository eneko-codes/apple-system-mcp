import Darwin
import Foundation
import Testing

@testable import SystemMCPCore

/// The only tests that call the real system, and they are limited on purpose: they read
/// the test process itself, and machine-wide totals that carry no names, paths or contents
/// (core count, memory page counts, boot time, load). They never list another process,
/// another process's sockets, or read a volume's name. A fake cannot catch the faults these
/// exist for: a wrong unit, a mis-decoded struct, a miscounted buffer.
@Suite("Darwin source, own process and machine totals only")
struct DarwinSelfTests {

    private let source = DarwinSystemSource()

    // MARK: Units

    @Test("CPU time comes back in nanoseconds, not Mach ticks")
    func cpuTimeIsNanoseconds() throws {
        let pid = getpid()
        let before = try #require(try source.processDetail(pid: pid)?.record.usage)

        // Burn about 400 ms of CPU on this thread.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var sink = 0.0
        while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start < 400_000_000 { sink += 1.0001 }
        #expect(sink > 0)

        let after = try #require(try source.processDetail(pid: pid)?.record.usage)
        let measured = after.cpuTimeNanoseconds - before.cpuTimeNanoseconds
        // Other tests may be running in this process, so only a lower bound is firm. Left
        // in ticks the figure would be about 40 times smaller and fail it by a wide margin.
        #expect(measured >= 350_000_000, "measured \(measured) ns for 400 ms of CPU")
    }

    @Test("The Mach tick conversion follows the timebase and saturates instead of trapping")
    func tickConversion() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks: UInt64 = 1_000_000
        #expect(
            SystemCalls.nanoseconds(fromMachTicks: ticks)
                == ticks * UInt64(timebase.numer) / UInt64(timebase.denom))
        #expect(SystemCalls.nanoseconds(fromMachTicks: .max) == .max)
        #expect(SystemCalls.nanoseconds(fromMachTicks: 0) == 0)
    }

    @Test("A wrapping counter difference crosses the 32-bit boundary")
    func wrappingDelta() {
        #expect(SystemCalls.wrappingDelta(from: 10, to: 25) == 15)
        #expect(SystemCalls.wrappingDelta(from: (1 << 32) - 5, to: 7) == 12)
    }

    @Test("The monotonic clock does not go backwards")
    func clockIsMonotonic() {
        let first = source.uptimeNanoseconds()
        let second = source.uptimeNanoseconds()
        #expect(second >= first)
        #expect(first > 0)
    }

    // MARK: Own process

    @Test("This process describes itself: identity, path, footprint and descriptors")
    func ownDetail() throws {
        let detail = try #require(try source.processDetail(pid: getpid()))
        let identity = detail.record.identity
        #expect(identity.pid == getpid())
        #expect(identity.userID == getuid())
        #expect(!identity.name.isEmpty)
        #expect(identity.path?.hasPrefix("/") == true)
        #expect(identity.parentPID > 0)
        let usage = try #require(detail.record.usage)
        #expect(usage.footprintBytes > 0)
        #expect(usage.threadCount >= 1)
        #expect((detail.openDescriptorCount ?? 0) >= 3)
        #expect(detail.startTime.map { $0 < Date() } == true)
    }

    @Test("A pid that cannot exist is reported as gone, not as an error")
    func absentProcess() throws {
        // Above the kernel's maximum pid value.
        #expect(try source.processDetail(pid: 2_000_000_000) == nil)
    }

    @Test("This process can read its own arguments")
    func ownArguments() throws {
        let arguments = try #require(try source.arguments(pid: getpid()))
        #expect(!arguments.isEmpty)
    }

    @Test("The current user resolves to a name")
    func ownUserName() {
        #expect(source.userName(userID: getuid()) != nil)
    }

    @Test("Sockets this process opens are decoded: port, address, state and protocol")
    func ownSockets() throws {
        let tcp = try openLoopbackSocket(type: SOCK_STREAM, listening: true)
        let udp = try openLoopbackSocket(type: SOCK_DGRAM, listening: false)
        defer {
            close(tcp.descriptor)
            close(udp.descriptor)
        }

        let sockets = source.sockets(ofProcess: getpid())
        let tcpRecord = try #require(sockets.first { $0.transport == .tcp && $0.localPort == tcp.port })
        #expect(tcpRecord.state == "LISTEN")
        #expect(tcpRecord.localAddress == "127.0.0.1")
        #expect(tcpRecord.isListening)
        #expect(tcpRecord.pid == getpid())

        let udpRecord = try #require(sockets.first { $0.transport == .udp && $0.localPort == udp.port })
        #expect(udpRecord.state == nil)
        #expect(udpRecord.remotePort == 0)
        #expect(udpRecord.isListening)
    }

    private func openLoopbackSocket(type: Int32, listening: Bool) throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, type, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        if listening { try #require(listen(descriptor, 4) == 0) }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return (descriptor, Int(UInt16(bigEndian: local.sin_port)))
    }

    @Test("The kernel's state numbers map to TCP state names, and a surprise is kept visible")
    func tcpStates() {
        #expect(DarwinSystemSource.tcpStateName(1) == "LISTEN")
        #expect(DarwinSystemSource.tcpStateName(4) == "ESTABLISHED")
        #expect(DarwinSystemSource.tcpStateName(10) == "TIME_WAIT")
        #expect(DarwinSystemSource.tcpStateName(99) == "UNKNOWN(99)")
    }

    @Test("Process states map from the kernel's numbers")
    func processStates() {
        #expect(DarwinSystemSource.state(fromStatus: 2) == .running)
        #expect(DarwinSystemSource.state(fromStatus: 3) == .sleeping)
        #expect(DarwinSystemSource.state(fromStatus: 5) == .zombie)
        #expect(DarwinSystemSource.state(fromStatus: 77) == .unknown)
    }

    // MARK: Machine totals

    @Test("CPU ticks cover every logical core and only ever grow")
    func coreTicks() throws {
        let first = try source.coreTicks()
        let second = try source.coreTicks()
        let hardware = try source.hardware()
        #expect(first.count == hardware.logicalCores)
        #expect(first.count == second.count)
        let total = { (ticks: [CoreTicks]) in ticks.reduce(UInt64(0)) { $0 + $1.user + $1.system + $1.idle + $1.nice } }
        #expect(total(second) >= total(first))
    }

    @Test("Memory counters are consistent with the physical memory installed")
    func memoryTotals() throws {
        let memory = try source.memory()
        #expect(memory.pageSize == 4096 || memory.pageSize == 16384)
        #expect(memory.totalBytes > 0)
        #expect(memory.usedBytes <= memory.totalBytes)
        #expect(memory.freeBytes <= memory.totalBytes)
        let swap = try source.swap()
        #expect(swap.usedBytes <= swap.totalBytes)
        if case .unknown(let value) = try source.memoryPressure() {
            Issue.record("memory pressure level \(value) is not one of the known ones")
        }
    }

    @Test("The kernel reports a build, a past boot time and a sensible load average")
    func kernelTotals() throws {
        let kernel = try source.kernel()
        #expect(!kernel.osVersion.isEmpty && !kernel.build.isEmpty)
        #expect(kernel.bootTime < Date())
        let load = try source.loadAverage()
        #expect(load.oneMinute >= 0 && load.fiveMinutes >= 0 && load.fifteenMinutes >= 0)
    }

    @Test("Hardware reports at least one core and groups that add up to the logical cores")
    func hardwareTotals() throws {
        let hardware = try source.hardware()
        #expect(hardware.logicalCores >= 1)
        #expect(hardware.physicalCores >= 1)
        #expect(hardware.memoryBytes > 0)
        if !hardware.coreGroups.isEmpty {
            #expect(hardware.coreGroups.map(\.count).reduce(0, +) == hardware.logicalCores)
        }
    }

    @Test("A loopback interface and a root volume exist")
    func interfacesAndVolumes() throws {
        let network = try source.networkSnapshot()
        #expect(network.interfaces.contains { $0.isLoopback })
        let volumes = try source.volumes()
        let root = try #require(volumes.first { $0.mountPoint == "/" })
        #expect(root.totalBytes > 0)
        #expect(root.availableBytes <= root.totalBytes)
    }
}
