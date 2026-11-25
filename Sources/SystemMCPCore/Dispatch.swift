import Foundation
import Synchronization

/// Waits this many milliseconds. A parameter so the tests drive the two-reading tools
/// without waiting and with scripted readings.
public typealias Sleep = @Sendable (Int) async throws -> Void

/// Returns the first of two outcomes: the work finishing, or the limit passing.
///
/// The timer is a dispatch timer, not a `Task.sleep`, and the work is not a child of a task
/// group. A synchronous system call that never returns holds its thread and cannot be
/// cancelled, and a task group would wait for it forever; a timer on the cooperative pool
/// could be starved by the same stuck threads. The stuck work is abandoned, not stopped:
/// its late result is discarded.
enum Deadline {

    private final class Outcome<Value: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<Value?, Never>?>

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = Mutex(continuation)
        }

        /// Only the first caller resumes; the other finds it empty.
        func resume(returning value: Value?) {
            continuation.withLock { pending in
                pending?.resume(returning: value)
                pending = nil
            }
        }
    }

    /// `nil` when `limit` passed before `work` finished.
    static func run<Value: Sendable>(
        within limit: Duration, _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        return await withCheckedContinuation { continuation in
            let outcome = Outcome<Value>(continuation)
            let task = Task {
                outcome.resume(returning: await work())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                outcome.resume(returning: nil)
                task.cancel()
            }
        }
    }
}

/// Routes a `tools/call` to the source and renders the answer.
///
/// Never touches the machine directly: everything goes through `SystemSource`, which is
/// what lets the tests drive every branch below against an in-memory double.
public struct SystemTools: ToolHandler {
    private let source: any SystemSource
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private let format = Format()

    /// The longest legitimate call is a 5 s sample plus a few readings. The limit stays
    /// well under the 60 s a client commonly waits, and so under `ToolStandard.timeLimit`,
    /// so the answer is ours and not the client's generic "no result".
    public static let defaultTimeout = Duration.seconds(30)

    public init(
        source: any SystemSource,
        sleep: @escaping Sleep = { try await Task.sleep(for: .milliseconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = SystemTools.defaultTimeout
    ) {
        self.source = source
        self.sleep = sleep
        self.now = now
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(seconds: Int(timeout.components.seconds)),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        return ToolOutput(text: Self.message(for: error), isError: true)
    }

    /// Only our own error types are described. Anything else becomes a generic failure, so
    /// no system-provided description, which can quote a path, ever reaches a result.
    static func message(for error: Error) -> String {
        switch error {
        case let error as ToolError:
            return error.message
        case SystemSourceError.callFailed(let function, let code):
            return ToolError.systemFailure(function: function, code: code).message
        case SystemSourceError.unexpectedShape(let function):
            return ToolError.systemFailure(function: function, code: -1).message
        default:
            return ToolError.systemFailure(function: "(unknown)", code: -1).message
        }
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments)

        switch parameters.name {
        case ToolCatalog.statusName: return status()
        case ToolCatalog.overviewName: return try await overview(arguments)
        case ToolCatalog.processesName: return try await processes(arguments)
        case ToolCatalog.processName: return try await process(arguments)
        case ToolCatalog.networkName: return try await network(arguments)
        case ToolCatalog.volumesName: return try volumes(arguments)
        case ToolCatalog.connectionsName: return try connections(arguments)
        case ToolCatalog.batteryName: return try battery()
        case ToolCatalog.disksName: return try await disks(arguments)
        default:
            throw ToolError.unknownTool(parameters.name)
        }
    }

    // MARK: Status

    private func status() -> String {
        // Best effort throughout: the point of this tool is to report what works.
        let snapshot = try? source.processSnapshot()
        return format.status(
            version: SystemMCPServer.version, binaryPath: Self.binaryPath,
            processID: ProcessInfo.processInfo.processIdentifier,
            osVersion: (try? source.kernel())?.osVersion,
            visibleProcesses: snapshot?.records.count,
            readableProcesses: snapshot?.records.values.filter { $0.usage != nil }.count)
    }

    // MARK: Overview

    private func overview(_ arguments: Arguments) async throws -> String {
        let sample = try arguments.int(
            "sample_ms", default: ToolCatalog.defaultSampleMilliseconds, in: ToolCatalog.sampleRange)
        let perCore = try arguments.bool("per_core", default: false)

        let before = try source.coreTicks()
        try await sleep(sample)
        let after = try source.coreTicks()

        // Pressure, swap and load are extras: a failure in one leaves the rest of the
        // answer intact, and the output says "unavailable" for it.
        let text = format.overview(
            .init(
                kernel: try source.kernel(), hardware: try source.hardware(),
                memory: try source.memory(), pressure: try? source.memoryPressure(),
                swap: try? source.swap(), load: try? source.loadAverage(),
                cpu: Metrics.cpuBreakdown(from: before, to: after),
                perCore: perCore
                    ? zip(before, after).map { Metrics.cpuBreakdown(from: $0, to: $1) } : nil,
                sampleMilliseconds: sample, now: now()))
        return ToolStandard.withNotices(arguments.notices, text)
    }

    // MARK: Processes

    private func processes(_ arguments: Arguments) async throws -> String {
        let sortKey = try arguments.choice(
            "sort_by", among: ToolCatalog.processSortKeys, default: "cpu")
        let nameFilter = try arguments.optionalString("name_contains")?.lowercased()
        let userFilter = try arguments.optionalString("user")?.lowercased()
        let parentFilter = try arguments.optionalIdentifier("parent_pid", in: ToolCatalog.pidRange)
            .map { Int32($0) }
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultProcessLimit, limits: ToolCatalog.processLimitRange)
        let sample = try arguments.int(
            "sample_ms", default: ToolCatalog.defaultSampleMilliseconds, in: ToolCatalog.sampleRange)

        let first = try source.processSnapshot()
        try await sleep(sample)
        let second = try source.processSnapshot()
        let elapsed = second.takenAtNanoseconds &- first.takenAtNanoseconds

        var names: [UInt32: String] = [:]
        func userName(_ userID: UInt32) -> String {
            if let known = names[userID] { return known }
            let resolved = source.userName(userID: userID) ?? "uid \(userID)"
            names[userID] = resolved
            return resolved
        }

        var rows = second.records.values.map { record in
            Format.ProcessRow(
                record: record, userName: userName(record.identity.userID),
                cpuPercent: Metrics.processCPUPercent(
                    before: first.records[record.identity.pid]?.usage, after: record.usage,
                    elapsedNanoseconds: elapsed))
        }
        let totalVisible = rows.count
        let totalReadable = rows.filter { $0.record.usage != nil }.count

        rows = rows.filter { row in
            if let nameFilter, !row.record.identity.name.lowercased().contains(nameFilter) { return false }
            if let userFilter,
                row.userName.lowercased() != userFilter
                    && String(row.record.identity.userID) != userFilter
            { return false }
            if let parentFilter, row.record.identity.parentPID != parentFilter { return false }
            return true
        }
        let matching = rows.count
        rows.sort { Self.precedes($0, $1, by: sortKey) }

        return ToolStandard.page(
            of: rows, limit: page.limit, offset: page.offset, things: "processes",
            notices: arguments.notices
        ) {
            format.processList(
                rows: $0, totalVisible: totalVisible, totalReadable: totalReadable,
                matching: matching, sortedBy: sortKey, sampleMilliseconds: sample)
        }
    }

    /// Descending for cpu and memory with unreadable rows last, ascending for name and pid.
    /// Ties fall back to pid so the order is stable between calls.
    static func precedes(_ lhs: Format.ProcessRow, _ rhs: Format.ProcessRow, by key: String) -> Bool {
        func descending<Value: Comparable>(_ a: Value?, _ b: Value?) -> Bool? {
            switch (a, b) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case (let a?, let b?): return a == b ? nil : a > b
            }
        }
        let decided: Bool?
        switch key {
        case "memory":
            decided = descending(lhs.record.usage?.footprintBytes, rhs.record.usage?.footprintBytes)
        case "name":
            let order = lhs.record.identity.name.localizedCaseInsensitiveCompare(rhs.record.identity.name)
            decided = order == .orderedSame ? nil : order == .orderedAscending
        case "pid":
            decided = nil
        default:
            decided = descending(lhs.cpuPercent, rhs.cpuPercent)
        }
        return decided ?? (lhs.record.identity.pid < rhs.record.identity.pid)
    }

    // MARK: One process

    private func process(_ arguments: Arguments) async throws -> String {
        let pid = Int32(try arguments.requiredIdentifier("pid", in: ToolCatalog.pidRange))
        let includeArguments = try arguments.bool("include_arguments", default: false)
        let children = try arguments.page(
            defaultLimit: ToolCatalog.defaultChildLimit, limits: ToolCatalog.childLimitRange)
        let characterOffset = try arguments.int(
            "character_offset", default: 0, in: ToolCatalog.offsetRange)
        let maxCharacters = try arguments.int(
            "max_characters", default: ToolCatalog.defaultMaxCharacters,
            in: ToolCatalog.maxCharactersRange)
        let sample = try arguments.int(
            "sample_ms", default: ToolCatalog.defaultSampleMilliseconds, in: ToolCatalog.sampleRange)

        guard let first = try source.processDetail(pid: pid) else {
            throw ToolError.processNotFound(pid: pid)
        }
        let startedAt = source.uptimeNanoseconds()
        try await sleep(sample)
        let second = try source.processDetail(pid: pid)
        let elapsed = source.uptimeNanoseconds() &- startedAt

        // The later reading is the one shown, unless the process is gone.
        let detail = second ?? first
        let identity = detail.record.identity

        // By pid, because the system lists children in no order a second page could rely on.
        let shownChildren = detail.childPIDs.sorted().dropFirst(children.offset).prefix(children.limit)
            .map { child in
                (pid: child, name: (try? source.processDetail(pid: child))?.record.identity.name ?? "?")
            }
        var maskedArguments: [String]?
        if includeArguments, let raw = try source.arguments(pid: pid) {
            maskedArguments = ProcessArguments.redact(raw)
        }

        let report = Format.ProcessReport(
            detail: detail,
            userName: source.userName(userID: identity.userID) ?? "uid \(identity.userID)",
            parentName: (try? source.processDetail(pid: identity.parentPID))?.record.identity.name,
            children: shownChildren, childOffset: children.offset,
            cpuPercent: second.flatMap {
                Metrics.processCPUPercent(
                    before: first.record.usage, after: $0.record.usage, elapsedNanoseconds: elapsed)
            },
            sampleMilliseconds: sample, arguments: maskedArguments,
            argumentsRequested: includeArguments, exitedDuringSample: second == nil, now: now())
        return ToolStandard.fitting(maxCharacters) {
            format.process(
                report, characterOffset: characterOffset, maxCharacters: $0,
                notices: arguments.notices)
        }
    }

    // MARK: Network

    private func network(_ arguments: Arguments) async throws -> String {
        let sample = try arguments.int(
            "sample_ms", default: ToolCatalog.defaultNetworkSampleMilliseconds,
            in: ToolCatalog.networkSampleRange)
        let includeInactive = try arguments.bool("include_inactive", default: false)
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultInterfaceLimit, limits: ToolCatalog.interfaceLimitRange)

        var latest = try source.networkSnapshot()
        var rates: [String: (received: Double?, sent: Double?)]?
        if sample > 0 {
            try await sleep(sample)
            let earlier = latest
            latest = try source.networkSnapshot()
            let elapsed = latest.takenAtNanoseconds &- earlier.takenAtNanoseconds
            let before = Dictionary(
                earlier.interfaces.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            var computed: [String: (received: Double?, sent: Double?)] = [:]
            for interface in latest.interfaces {
                guard let previous = before[interface.name] else { continue }
                computed[interface.name] = (
                    Metrics.bytesPerSecond(
                        before: previous.receivedBytes, after: interface.receivedBytes,
                        elapsedNanoseconds: elapsed),
                    Metrics.bytesPerSecond(
                        before: previous.sentBytes, after: interface.sentBytes,
                        elapsedNanoseconds: elapsed)
                )
            }
            rates = computed
        }

        let shown = latest.interfaces.filter { interface in
            includeInactive
                || (interface.isUp
                    && !(interface.addresses.isEmpty && interface.receivedBytes == 0
                        && interface.sentBytes == 0))
        }.sorted { Self.namePrecedes($0.name, $1.name) }
        return ToolStandard.page(
            of: shown, limit: page.limit, offset: page.offset, things: "interfaces",
            notices: arguments.notices
        ) {
            format.network(
                interfaces: $0, matching: shown.count, rates: rates, sampleMilliseconds: sample,
                hidden: latest.interfaces.count - shown.count)
        }
    }

    /// "en2" before "en10": the order a page of names is given in, the same on every call.
    static func namePrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedAscending
    }

    // MARK: Volumes

    private func volumes(_ arguments: Arguments) throws -> String {
        let includeHidden = try arguments.bool("include_hidden", default: false)
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultVolumeLimit, limits: ToolCatalog.volumeLimitRange)
        let all = try source.volumes()
        let shown = (includeHidden ? all : all.filter { !Self.isSystemVolume($0) })
            .sorted { Self.namePrecedes($0.mountPoint, $1.mountPoint) }
        return ToolStandard.page(
            of: shown, limit: page.limit, offset: page.offset, things: "volumes",
            notices: arguments.notices
        ) {
            format.volumes($0, matching: shown.count, hidden: all.count - shown.count)
        }
    }

    /// File systems that are views or plumbing, not storage: `devfs` (/dev), `autofs`,
    /// `nullfs` (the translocated copy of a downloaded app) and `devicefs` (a connected
    /// device's file system), none of which has capacity of its own.
    private static let virtualFileSystems: Set<String> = ["devfs", "autofs", "nullfs", "devicefs"]

    /// Mounts that exist for the system's own bookkeeping and that nobody asks about when
    /// they ask what is mounted. `/System/Volumes/Data` is the user's data and stays.
    static func isSystemVolume(_ volume: Volume) -> Bool {
        if virtualFileSystems.contains(volume.fileSystem) { return true }
        return volume.mountPoint.hasPrefix("/System/Volumes/")
            && volume.mountPoint != "/System/Volumes/Data"
    }

    // MARK: Connections

    private func connections(_ arguments: Arguments) throws -> String {
        let state = try arguments.choice(
            "state", among: ToolCatalog.socketStates, default: "listening")
        let transport = try arguments.choice(
            "protocol", among: ToolCatalog.socketProtocols, default: "all")
        let pidFilter = try arguments.optionalIdentifier("pid", in: ToolCatalog.pidRange)
            .map { Int32($0) }
        let portFilter = try arguments.optionalIdentifier("port", in: ToolCatalog.portRange)
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultConnectionLimit, limits: ToolCatalog.connectionLimitRange)

        let processes = try source.processSnapshot()
        let readable = processes.records.values.filter { $0.usage != nil }.count

        let matching = try source.sockets().filter { socket in
            if transport != "all" && socket.transport.rawValue != transport { return false }
            if let pidFilter, socket.pid != pidFilter { return false }
            if let portFilter, socket.localPort != portFilter && socket.remotePort != portFilter {
                return false
            }
            switch state {
            case "listening": return socket.isListening
            case "established": return socket.state == "ESTABLISHED"
            default: return true
            }
        }.sorted {
            // Down to the addresses, so that two sockets never tie and a page boundary
            // falls in the same place on the next call.
            ($0.localPort, $0.pid, $0.transport.rawValue, $0.localAddress, $0.remotePort, $0.remoteAddress)
                < ($1.localPort, $1.pid, $1.transport.rawValue, $1.localAddress, $1.remotePort, $1.remoteAddress)
        }.map {
            Format.SocketRow(
                socket: $0, processName: processes.records[$0.pid]?.identity.name ?? "(exited)")
        }
        return ToolStandard.page(
            of: matching, limit: page.limit, offset: page.offset, things: "sockets",
            notices: arguments.notices
        ) {
            format.connections(
                rows: $0, matching: matching.count, readableProcesses: readable,
                visibleProcesses: processes.records.count)
        }
    }

    // MARK: Battery

    private func battery() throws -> String {
        format.battery(try source.powerStatus())
    }

    // MARK: Disks

    private func disks(_ arguments: Arguments) async throws -> String {
        let sample = try arguments.int(
            "sample_ms", default: ToolCatalog.defaultDiskSampleMilliseconds,
            in: ToolCatalog.diskSampleRange)
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultDiskLimit, limits: ToolCatalog.diskLimitRange)

        var latest = try source.diskSnapshot()
        var rates: [UInt64: Format.DiskRate]?
        if sample > 0 {
            try await sleep(sample)
            let earlier = latest
            latest = try source.diskSnapshot()
            let elapsed = latest.takenAtNanoseconds &- earlier.takenAtNanoseconds
            let before = Dictionary(
                earlier.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var computed: [UInt64: Format.DiskRate] = [:]
            for device in latest.devices {
                guard let previous = before[device.id] else { continue }
                computed[device.id] = Format.DiskRate(
                    readBytesPerSecond: Metrics.bytesPerSecond(
                        before: previous.readBytes, after: device.readBytes, elapsedNanoseconds: elapsed),
                    writtenBytesPerSecond: Metrics.bytesPerSecond(
                        before: previous.writtenBytes, after: device.writtenBytes,
                        elapsedNanoseconds: elapsed),
                    readsPerSecond: Metrics.bytesPerSecond(
                        before: previous.readOperations, after: device.readOperations,
                        elapsedNanoseconds: elapsed),
                    writesPerSecond: Metrics.bytesPerSecond(
                        before: previous.writtenOperations, after: device.writtenOperations,
                        elapsedNanoseconds: elapsed),
                    readLatencyNanoseconds: Self.latency(
                        previous.readTimeNanoseconds, device.readTimeNanoseconds,
                        previous.readOperations, device.readOperations),
                    writeLatencyNanoseconds: Self.latency(
                        previous.writeTimeNanoseconds, device.writeTimeNanoseconds,
                        previous.writtenOperations, device.writtenOperations))
            }
            rates = computed
        }
        let devices = latest.devices.sorted {
            $0.name == $1.name ? $0.id < $1.id : Self.namePrecedes($0.name, $1.name)
        }
        return ToolStandard.page(
            of: devices, limit: page.limit, offset: page.offset, things: "storage drivers",
            notices: arguments.notices
        ) {
            format.disks(devices: $0, matching: devices.count, rates: rates, sampleMilliseconds: sample)
        }
    }

    /// `nil` when a counter went backwards, as with every other rate here.
    private static func latency(_ timeBefore: UInt64, _ timeAfter: UInt64, _ opsBefore: UInt64, _ opsAfter: UInt64)
        -> Double?
    {
        guard timeAfter >= timeBefore, opsAfter >= opsBefore else { return nil }
        return Metrics.averageLatencyNanoseconds(
            timeDelta: timeAfter - timeBefore, operationsDelta: opsAfter - opsBefore)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
