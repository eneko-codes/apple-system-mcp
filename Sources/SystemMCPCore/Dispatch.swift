import Foundation
import MCP

/// Waits this many milliseconds. A parameter so the tests drive the two-reading tools
/// without waiting and with scripted readings.
public typealias Sleep = @Sendable (Int) async throws -> Void

/// Routes a `tools/call` to the source and renders the answer.
///
/// Never touches the machine directly: everything goes through `SystemSource`, which is
/// what lets the tests drive every branch below against an in-memory double.
public struct SystemTools: Sendable {
    private let source: any SystemSource
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let format = Format()

    public init(
        source: any SystemSource,
        sleep: @escaping Sleep = { try await Task.sleep(for: .milliseconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.sleep = sleep
        self.now = now
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        let started = ContinuousClock.now
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return .init(
                content: [.text(text: Self.message(for: error), annotations: nil, _meta: nil)],
                isError: true)
        }
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

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments)

        switch parameters.name {
        case ToolCatalog.statusName: return status()
        case ToolCatalog.overviewName: return try await overview(arguments)
        case ToolCatalog.processesName: return try await processes(arguments)
        case ToolCatalog.processName: return try await process(arguments)
        case ToolCatalog.networkName: return try await network(arguments)
        case ToolCatalog.volumesName: return try volumes(arguments)
        case ToolCatalog.connectionsName: return try connections(arguments)
        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
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
        return format.overview(
            .init(
                kernel: try source.kernel(), hardware: try source.hardware(),
                memory: try source.memory(), pressure: try? source.memoryPressure(),
                swap: try? source.swap(), load: try? source.loadAverage(),
                cpu: Metrics.cpuBreakdown(from: before, to: after),
                perCore: perCore
                    ? zip(before, after).map { Metrics.cpuBreakdown(from: $0, to: $1) } : nil,
                sampleMilliseconds: sample, now: now()))
    }

    // MARK: Processes

    private func processes(_ arguments: Arguments) async throws -> String {
        let sortKey = try arguments.choice(
            "sort_by", among: ToolCatalog.processSortKeys, default: "cpu")
        let nameFilter = arguments.optionalString("name_contains")?.lowercased()
        let userFilter = arguments.optionalString("user")?.lowercased()
        let parentFilter = try arguments.optionalInt("parent_pid").map { Int32(truncatingIfNeeded: $0) }
        let limit = try arguments.int(
            "limit", default: ToolCatalog.defaultProcessLimit, in: ToolCatalog.processLimitRange)
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

        return format.processList(
            rows: Array(rows.prefix(limit)), totalVisible: totalVisible,
            totalReadable: totalReadable, matching: matching, sortedBy: sortKey,
            sampleMilliseconds: sample)
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
        let pid = Int32(truncatingIfNeeded: try arguments.requiredInt("pid"))
        let includeArguments = try arguments.bool("include_arguments", default: false)
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

        let children = detail.childPIDs.prefix(10).map { child in
            (pid: child, name: (try? source.processDetail(pid: child))?.record.identity.name ?? "?")
        }
        var maskedArguments: [String]?
        if includeArguments, let raw = try source.arguments(pid: pid) {
            maskedArguments = ProcessArguments.redact(raw)
        }

        return format.process(
            .init(
                detail: detail,
                userName: source.userName(userID: identity.userID) ?? "uid \(identity.userID)",
                parentName: (try? source.processDetail(pid: identity.parentPID))?.record.identity.name,
                children: Array(children),
                cpuPercent: second.flatMap {
                    Metrics.processCPUPercent(
                        before: first.record.usage, after: $0.record.usage, elapsedNanoseconds: elapsed)
                },
                sampleMilliseconds: sample, arguments: maskedArguments,
                argumentsRequested: includeArguments, exitedDuringSample: second == nil, now: now()))
    }

    // MARK: Network

    private func network(_ arguments: Arguments) async throws -> String {
        let sample = try arguments.int(
            "sample_ms", default: ToolCatalog.defaultNetworkSampleMilliseconds,
            in: ToolCatalog.networkSampleRange)
        let includeInactive = try arguments.bool("include_inactive", default: false)

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
        }
        return format.network(
            interfaces: shown, rates: rates, sampleMilliseconds: sample,
            hidden: latest.interfaces.count - shown.count)
    }

    // MARK: Volumes

    private func volumes(_ arguments: Arguments) throws -> String {
        let includeHidden = try arguments.bool("include_hidden", default: false)
        let all = try source.volumes()
        let shown = includeHidden ? all : all.filter { !Self.isSystemVolume($0) }
        return format.volumes(shown, hidden: all.count - shown.count)
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
        let pidFilter = try arguments.optionalInt("pid").map { Int32(truncatingIfNeeded: $0) }
        let portFilter = try arguments.optionalInt("port")
        let limit = try arguments.int(
            "limit", default: ToolCatalog.defaultConnectionLimit, in: ToolCatalog.connectionLimitRange)

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
            ($0.localPort, $0.pid, $0.transport.rawValue) < ($1.localPort, $1.pid, $1.transport.rawValue)
        }

        let rows = matching.prefix(limit).map {
            Format.SocketRow(
                socket: $0, processName: processes.records[$0.pid]?.identity.name ?? "(exited)")
        }
        return format.connections(
            rows: Array(rows), matching: matching.count, readableProcesses: readable,
            visibleProcesses: processes.records.count)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
