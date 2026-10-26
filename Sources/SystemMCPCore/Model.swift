import Foundation

// Plain values describing the machine. Nothing here knows how it was read, which is what
// lets every tool be driven by an in-memory double.

public enum ProcessState: String, Sendable, Equatable {
    case idle, running, sleeping, stopped, zombie, unknown
}

public struct ProcessIdentity: Sendable, Equatable {
    public var pid: Int32
    public var parentPID: Int32
    public var userID: UInt32
    /// Last component of `path` when the path is known, otherwise the kernel's short name.
    public var name: String
    public var path: String?
    public var state: ProcessState

    public init(
        pid: Int32, parentPID: Int32, userID: UInt32, name: String, path: String? = nil,
        state: ProcessState = .unknown
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.path = path
        self.state = state
    }
}

/// Counters the kernel only hands out for processes of the same user, unless the caller
/// is root. `nil` where this type is optional means exactly that: not readable.
public struct ProcessUsage: Sendable, Equatable {
    /// User plus system CPU time since the process started, already in nanoseconds.
    public var cpuTimeNanoseconds: UInt64
    /// Physical memory footprint, the figure the kernel charges to the process.
    public var footprintBytes: UInt64
    public var residentBytes: UInt64
    public var threadCount: Int
    public var diskReadBytes: UInt64
    public var diskWrittenBytes: UInt64

    public init(
        cpuTimeNanoseconds: UInt64, footprintBytes: UInt64, residentBytes: UInt64,
        threadCount: Int, diskReadBytes: UInt64 = 0, diskWrittenBytes: UInt64 = 0
    ) {
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.threadCount = threadCount
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
    }
}

public struct ProcessRecord: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var usage: ProcessUsage?

    public init(identity: ProcessIdentity, usage: ProcessUsage?) {
        self.identity = identity
        self.usage = usage
    }
}

public struct ProcessSnapshot: Sendable, Equatable {
    /// Monotonic clock reading, in nanoseconds, taken when the snapshot was gathered.
    public var takenAtNanoseconds: UInt64
    public var records: [Int32: ProcessRecord]

    public init(takenAtNanoseconds: UInt64, records: [Int32: ProcessRecord]) {
        self.takenAtNanoseconds = takenAtNanoseconds
        self.records = records
    }
}

public struct ProcessDetail: Sendable, Equatable {
    public var record: ProcessRecord
    public var startTime: Date?
    public var workingDirectory: String?
    public var childPIDs: [Int32]
    public var openDescriptorCount: Int?

    public init(
        record: ProcessRecord, startTime: Date? = nil, workingDirectory: String? = nil,
        childPIDs: [Int32] = [], openDescriptorCount: Int? = nil
    ) {
        self.record = record
        self.startTime = startTime
        self.workingDirectory = workingDirectory
        self.childPIDs = childPIDs
        self.openDescriptorCount = openDescriptorCount
    }
}

/// Cumulative scheduler ticks of one core since boot.
public struct CoreTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public struct MemorySnapshot: Sendable, Equatable {
    public var pageSize: UInt64
    public var totalBytes: UInt64
    /// Page counts, exactly as the kernel reports them.
    public var freePages: UInt64
    public var activePages: UInt64
    public var inactivePages: UInt64
    public var wiredPages: UInt64
    public var compressedPages: UInt64
    public var purgeablePages: UInt64
    public var speculativePages: UInt64
    /// Pages backing files (the file cache).
    public var fileBackedPages: UInt64
    /// Pages backing process memory.
    public var anonymousPages: UInt64
    public var swapIns: UInt64
    public var swapOuts: UInt64

    public init(
        pageSize: UInt64, totalBytes: UInt64, freePages: UInt64, activePages: UInt64,
        inactivePages: UInt64, wiredPages: UInt64, compressedPages: UInt64,
        purgeablePages: UInt64, speculativePages: UInt64, fileBackedPages: UInt64,
        anonymousPages: UInt64, swapIns: UInt64, swapOuts: UInt64
    ) {
        self.pageSize = pageSize
        self.totalBytes = totalBytes
        self.freePages = freePages
        self.activePages = activePages
        self.inactivePages = inactivePages
        self.wiredPages = wiredPages
        self.compressedPages = compressedPages
        self.purgeablePages = purgeablePages
        self.speculativePages = speculativePages
        self.fileBackedPages = fileBackedPages
        self.anonymousPages = anonymousPages
        self.swapIns = swapIns
        self.swapOuts = swapOuts
    }

    /// An approximation. The system documents no formula for "memory in use": this adds
    /// the memory processes own (anonymous pages not marked purgeable), the wired pages
    /// and the compressor's pages.
    public var usedBytes: UInt64 {
        let owned = anonymousPages > purgeablePages ? anonymousPages - purgeablePages : 0
        return (owned + wiredPages + compressedPages) * pageSize
    }

    /// Free pages, with speculative ones reported separately because the kernel counts
    /// them inside its free total.
    public var freeBytes: UInt64 {
        (freePages > speculativePages ? freePages - speculativePages : 0) * pageSize
    }
}

public enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical
    case unknown(Int32)

    public init(rawValue: Int32) {
        switch rawValue {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown(rawValue)
        }
    }

    public var label: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        case .unknown(let value): return "unknown (\(value))"
        }
    }
}

public struct SwapUsage: Sendable, Equatable {
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var isEncrypted: Bool

    public init(totalBytes: UInt64, usedBytes: UInt64, isEncrypted: Bool) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.isEncrypted = isEncrypted
    }
}

/// One class of core, as the kernel names it ("Performance", "Efficiency"). A chip may
/// have more than two, so the names are read rather than assumed.
public struct CoreGroup: Sendable, Equatable {
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct HardwareInfo: Sendable, Equatable {
    public var chip: String?
    public var logicalCores: Int
    public var physicalCores: Int
    /// Empty on a machine whose cores are all alike.
    public var coreGroups: [CoreGroup]
    public var memoryBytes: UInt64

    public init(
        chip: String?, logicalCores: Int, physicalCores: Int, coreGroups: [CoreGroup],
        memoryBytes: UInt64
    ) {
        self.chip = chip
        self.logicalCores = logicalCores
        self.physicalCores = physicalCores
        self.coreGroups = coreGroups
        self.memoryBytes = memoryBytes
    }
}

public struct KernelInfo: Sendable, Equatable {
    public var osVersion: String
    public var build: String
    public var bootTime: Date

    public init(osVersion: String, build: String, bootTime: Date) {
        self.osVersion = osVersion
        self.build = build
        self.bootTime = bootTime
    }
}

public struct LoadAverage: Sendable, Equatable {
    public var oneMinute: Double
    public var fiveMinutes: Double
    public var fifteenMinutes: Double

    public init(oneMinute: Double, fiveMinutes: Double, fifteenMinutes: Double) {
        self.oneMinute = oneMinute
        self.fiveMinutes = fiveMinutes
        self.fifteenMinutes = fifteenMinutes
    }
}

public struct NetworkInterface: Sendable, Equatable {
    public var name: String
    public var isUp: Bool
    public var isLoopback: Bool
    public var addresses: [String]
    /// Cumulative since boot, 64-bit.
    public var receivedBytes: UInt64
    public var sentBytes: UInt64
    public var receivedPackets: UInt64
    public var sentPackets: UInt64
    public var receiveErrors: UInt64
    public var sendErrors: UInt64

    public init(
        name: String, isUp: Bool, isLoopback: Bool, addresses: [String], receivedBytes: UInt64,
        sentBytes: UInt64, receivedPackets: UInt64 = 0, sentPackets: UInt64 = 0,
        receiveErrors: UInt64 = 0, sendErrors: UInt64 = 0
    ) {
        self.name = name
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.addresses = addresses
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.receivedPackets = receivedPackets
        self.sentPackets = sentPackets
        self.receiveErrors = receiveErrors
        self.sendErrors = sendErrors
    }
}

public struct NetworkSnapshot: Sendable, Equatable {
    public var takenAtNanoseconds: UInt64
    public var interfaces: [NetworkInterface]

    public init(takenAtNanoseconds: UInt64, interfaces: [NetworkInterface]) {
        self.takenAtNanoseconds = takenAtNanoseconds
        self.interfaces = interfaces
    }
}

public struct Volume: Sendable, Equatable {
    public var mountPoint: String
    public var device: String
    public var fileSystem: String
    public var totalBytes: UInt64
    /// Free blocks, including those only the superuser may use.
    public var freeBytes: UInt64
    /// Free blocks an ordinary process may use.
    public var availableBytes: UInt64
    public var isReadOnly: Bool
    public var isLocal: Bool

    public init(
        mountPoint: String, device: String, fileSystem: String, totalBytes: UInt64,
        freeBytes: UInt64, availableBytes: UInt64, isReadOnly: Bool, isLocal: Bool
    ) {
        self.mountPoint = mountPoint
        self.device = device
        self.fileSystem = fileSystem
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
        self.isReadOnly = isReadOnly
        self.isLocal = isLocal
    }
}

public enum SocketProtocol: String, Sendable, Equatable {
    case tcp, udp
}

public struct SocketRecord: Sendable, Equatable {
    public var pid: Int32
    public var transport: SocketProtocol
    public var localAddress: String
    public var localPort: Int
    public var remoteAddress: String
    public var remotePort: Int
    /// TCP state name; `nil` for UDP, which has none.
    public var state: String?

    public init(
        pid: Int32, transport: SocketProtocol, localAddress: String, localPort: Int,
        remoteAddress: String, remotePort: Int, state: String?
    ) {
        self.pid = pid
        self.transport = transport
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
    }

    /// A TCP socket in LISTEN, or a UDP socket that is bound to a port and has no peer:
    /// both are waiting for traffic. A UDP socket with local port 0 was created but never
    /// bound, so nothing can reach it, and one process can hold dozens of them.
    public var isListening: Bool {
        switch transport {
        case .tcp: return state == "LISTEN"
        case .udp: return localPort != 0 && remotePort == 0
        }
    }
}
