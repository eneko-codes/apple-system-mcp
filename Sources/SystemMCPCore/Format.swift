import Foundation

/// Plain-text rendering of every tool result. Pure: it is handed finished values and
/// reads nothing from the machine.
public struct Format: Sendable {

    public init() {}

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func padLeft(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? String(repeating: " ", count: shortfall) + text : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// Binary units, matching what the system's own storage and memory panels show.
    public static func bytes(_ count: UInt64) -> String {
        guard count >= 1024 else { return "\(count) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(count) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    static func bytesPerSecond(_ rate: Double?) -> String {
        guard let rate else { return "n/a" }
        return bytes(UInt64(max(rate, 0))) + "/s"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f%%", value)
    }

    /// "17d 5h", "3h 21m", "42s": the two largest units that are not zero.
    static func duration(seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(rest)s" }
        return "\(rest)s"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }

    /// Collapses a multi-line value onto one line, so the one-row-per-item contract that
    /// makes a listing scannable survives a name containing a newline.
    static func oneLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    // MARK: Overview

    public struct Overview: Sendable {
        public var kernel: KernelInfo
        public var hardware: HardwareInfo
        public var memory: MemorySnapshot
        public var pressure: MemoryPressure?
        public var swap: SwapUsage?
        public var load: LoadAverage?
        public var cpu: Metrics.CPUBreakdown?
        public var perCore: [Metrics.CPUBreakdown?]?
        public var sampleMilliseconds: Int
        public var now: Date

        public init(
            kernel: KernelInfo, hardware: HardwareInfo, memory: MemorySnapshot,
            pressure: MemoryPressure?, swap: SwapUsage?, load: LoadAverage?,
            cpu: Metrics.CPUBreakdown?, perCore: [Metrics.CPUBreakdown?]?, sampleMilliseconds: Int,
            now: Date
        ) {
            self.kernel = kernel
            self.hardware = hardware
            self.memory = memory
            self.pressure = pressure
            self.swap = swap
            self.load = load
            self.cpu = cpu
            self.perCore = perCore
            self.sampleMilliseconds = sampleMilliseconds
            self.now = now
        }
    }

    public func overview(_ data: Overview) -> String {
        let uptime = Self.duration(seconds: data.now.timeIntervalSince(data.kernel.bootTime))
        var cores = "\(data.hardware.logicalCores) cores"
        if !data.hardware.coreGroups.isEmpty {
            cores += " ("
                + data.hardware.coreGroups.map { "\($0.count) \($0.name)" }.joined(separator: " + ")
                + ")"
        }

        var text = "macOS \(data.kernel.osVersion) (\(data.kernel.build)) · up \(uptime)"
        text += " · booted \(Self.timestamp(data.kernel.bootTime))\n"
        text += [data.hardware.chip, cores, Self.bytes(data.hardware.memoryBytes)]
            .compactMap { $0 }.joined(separator: " · ")

        text += "\n\nCPU, sampled over \(data.sampleMilliseconds) ms\n"
        if let cpu = data.cpu {
            text += Self.block([
                ("busy", "\(Self.percent(cpu.busyPercent)) (user \(Self.percent(cpu.userPercent)) · system \(Self.percent(cpu.systemPercent)))"),
                ("idle", Self.percent(cpu.idlePercent)),
                (
                    "load average",
                    data.load.map {
                        String(format: "%.2f %.2f %.2f  (1, 5 and 15 minutes)", $0.oneMinute, $0.fiveMinutes, $0.fifteenMinutes)
                    }
                ),
            ])
        } else {
            text += "  (the sample was too short to measure; ask for a longer sample_ms)"
        }
        if let perCore = data.perCore {
            text += "\n  per core:\n"
            text += perCore.enumerated().map { index, breakdown in
                "    core \(Self.padLeft(String(index), to: 2))  \(Self.percent(breakdown?.busyPercent))"
            }.joined(separator: "\n")
        }

        let memory = data.memory
        let appBytes =
            (memory.anonymousPages > memory.purgeablePages
                ? memory.anonymousPages - memory.purgeablePages : 0) * memory.pageSize
        text += "\n\nMemory\n"
        text += Self.block([
            ("in use", "\(Self.bytes(memory.usedBytes)) of \(Self.bytes(memory.totalBytes)) (an approximation: the system documents no exact formula)"),
            ("pressure", data.pressure?.label ?? "unavailable"),
            ("app memory", Self.bytes(appBytes)),
            ("wired", Self.bytes(memory.wiredPages * memory.pageSize)),
            ("compressed", Self.bytes(memory.compressedPages * memory.pageSize)),
            ("file cache", Self.bytes((memory.fileBackedPages + memory.purgeablePages) * memory.pageSize)),
            ("free", Self.bytes(memory.freeBytes)),
            (
                "swap",
                data.swap.map {
                    "\(Self.bytes($0.usedBytes)) used of \(Self.bytes($0.totalBytes))"
                        + ($0.isEncrypted ? ", encrypted" : "")
                } ?? "unavailable"
            ),
            ("paging since boot", "\(memory.swapIns) pages swapped in · \(memory.swapOuts) swapped out"),
        ])
        return text
    }

    // MARK: Processes

    public struct ProcessRow: Sendable, Equatable {
        public var record: ProcessRecord
        public var userName: String
        public var cpuPercent: Double?

        public init(record: ProcessRecord, userName: String, cpuPercent: Double?) {
            self.record = record
            self.userName = userName
            self.cpuPercent = cpuPercent
        }
    }

    public func processList(
        rows: [ProcessRow], totalVisible: Int, totalReadable: Int, matching: Int, sortedBy: String,
        sampleMilliseconds: Int
    ) -> String {
        var text = "Processes: \(totalVisible) visible; CPU and memory are readable for \(totalReadable)."
        let hidden = totalVisible - totalReadable
        if hidden > 0 {
            text += " The other \(hidden) belong to other users or to the system, and macOS only"
            text += " exposes their counters to root; they show n/a."
        }
        text += "\nSorted by \(sortedBy), sampled over \(sampleMilliseconds) ms."
        text += " CPU % is of one core: 100 is one core fully busy, and a process on four cores can reach 400."

        guard !rows.isEmpty else {
            return text + "\n\n  (no process matches those filters)"
        }
        text += "\nShowing \(rows.count) of \(matching) matching.\n\n"
        text += "  " + Self.padLeft("PID", to: 7) + Self.padLeft("CPU %", to: 8)
            + Self.padLeft("MEMORY", to: 10) + Self.padLeft("THREADS", to: 9) + "  "
            + Self.pad("USER", to: 12) + "NAME\n"
        text += rows.map { row in
            let usage = row.record.usage
            return "  " + Self.padLeft(String(row.record.identity.pid), to: 7)
                + Self.padLeft(row.cpuPercent.map { String(format: "%.1f", $0) } ?? "n/a", to: 8)
                + Self.padLeft(usage.map { Self.bytes($0.footprintBytes) } ?? "n/a", to: 10)
                + Self.padLeft(usage.map { String($0.threadCount) } ?? "n/a", to: 9) + "  "
                + Self.pad(Self.oneLine(row.userName), to: 12) + Self.oneLine(row.record.identity.name)
        }.joined(separator: "\n")
        return text
    }

    public struct ProcessReport: Sendable {
        public var detail: ProcessDetail
        public var userName: String
        public var parentName: String?
        public var children: [(pid: Int32, name: String)]
        public var cpuPercent: Double?
        public var sampleMilliseconds: Int
        public var arguments: [String]?
        public var argumentsRequested: Bool
        public var exitedDuringSample: Bool
        public var now: Date

        public init(
            detail: ProcessDetail, userName: String, parentName: String?,
            children: [(pid: Int32, name: String)], cpuPercent: Double?, sampleMilliseconds: Int,
            arguments: [String]?, argumentsRequested: Bool, exitedDuringSample: Bool, now: Date
        ) {
            self.detail = detail
            self.userName = userName
            self.parentName = parentName
            self.children = children
            self.cpuPercent = cpuPercent
            self.sampleMilliseconds = sampleMilliseconds
            self.arguments = arguments
            self.argumentsRequested = argumentsRequested
            self.exitedDuringSample = exitedDuringSample
            self.now = now
        }
    }

    public func process(_ report: ProcessReport) -> String {
        let identity = report.detail.record.identity
        let usage = report.detail.record.usage

        var rows: [(String, String?)] = [
            ("state", identity.state.rawValue),
            ("path", identity.path.map(Self.oneLine) ?? "(not readable)"),
            ("user", "\(Self.oneLine(report.userName)) (uid \(identity.userID))"),
            (
                "parent",
                "\(identity.parentPID)" + (report.parentName.map { " (\(Self.oneLine($0)))" } ?? "")
            ),
        ]
        if let start = report.detail.startTime {
            rows.append((
                "started",
                "\(Self.timestamp(start)) (\(Self.duration(seconds: report.now.timeIntervalSince(start))) ago)"
            ))
        }
        if let usage {
            rows.append((
                "cpu",
                (report.cpuPercent.map { "\(Self.percent($0)) of one core over \(report.sampleMilliseconds) ms" }
                    ?? "n/a")
                    + " · \(Self.duration(seconds: Double(usage.cpuTimeNanoseconds) / 1e9)) of CPU time in total"
            ))
            rows.append(("memory", "\(Self.bytes(usage.footprintBytes)) footprint · \(Self.bytes(usage.residentBytes)) resident"))
            rows.append(("threads", String(usage.threadCount)))
            rows.append(("disk", "\(Self.bytes(usage.diskReadBytes)) read · \(Self.bytes(usage.diskWrittenBytes)) written since it started"))
        } else {
            rows.append((
                "usage",
                "CPU, memory, threads and disk are not readable: this process belongs to another user or to the system, and macOS only exposes them to root."
            ))
        }
        if let descriptors = report.detail.openDescriptorCount {
            rows.append(("descriptors", "\(descriptors) open"))
        }
        rows.append(("directory", report.detail.workingDirectory.map(Self.oneLine)))
        if !report.children.isEmpty {
            let shown = report.children.map { "\($0.pid) (\(Self.oneLine($0.name)))" }
            let extra = report.detail.childPIDs.count - report.children.count
            rows.append((
                "children",
                shown.joined(separator: ", ") + (extra > 0 ? ", and \(extra) more" : "")
            ))
        }

        var text = "Process \(identity.pid) — \(Self.oneLine(identity.name))\n" + Self.block(rows)
        if report.exitedDuringSample {
            text += "\n\n  The process exited during the \(report.sampleMilliseconds) ms sample, so the CPU rate is not available."
        }
        if report.argumentsRequested {
            if let arguments = report.arguments {
                text += "\n\nArguments (best-effort masking of values that look like secrets; the environment is never read):\n"
                text += arguments.enumerated().map { index, argument in
                    "  [\(index)] \(Self.oneLine(argument))"
                }.joined(separator: "\n")
            } else {
                text += "\n\nArguments: not readable for this process."
            }
        }
        return text
    }

    // MARK: Network

    public func network(
        interfaces: [NetworkInterface], rates: [String: (received: Double?, sent: Double?)]?,
        sampleMilliseconds: Int, hidden: Int
    ) -> String {
        var text = "Network interfaces: \(interfaces.count) shown"
        if hidden > 0 { text += ", \(hidden) down or idle hidden" }
        text += ". Totals are cumulative since boot"
        text += rates == nil ? "." : "; rates are over \(sampleMilliseconds) ms."

        guard !interfaces.isEmpty else { return text + "\n\n  (none)" }
        let rows = interfaces.map { interface -> String in
            var line = "  \(interface.name) — \(interface.isUp ? "up" : "down")"
            if interface.isLoopback { line += ", loopback" }
            if !interface.addresses.isEmpty { line += "\n      " + interface.addresses.joined(separator: ", ") }
            let rate = rates?[interface.name]
            line += "\n      received \(Self.bytes(interface.receivedBytes))"
                + (rate.map { " (\(Self.bytesPerSecond($0.received)))" } ?? "")
                + " · sent \(Self.bytes(interface.sentBytes))"
                + (rate.map { " (\(Self.bytesPerSecond($0.sent)))" } ?? "")
            line += "\n      packets in \(interface.receivedPackets) out \(interface.sentPackets)"
                + " · errors in \(interface.receiveErrors) out \(interface.sendErrors)"
            return line
        }
        return text + "\n\n" + rows.joined(separator: "\n")
    }

    // MARK: Volumes

    public func volumes(_ volumes: [Volume], hidden: Int) -> String {
        var text = "Volumes: \(volumes.count) shown"
        if hidden > 0 { text += ", \(hidden) system volumes hidden (pass include_hidden to list them)" }
        text += ". Available is what an ordinary process may write."
        text += " It can differ from the space Finder reports, which also counts purgeable files."
        guard !volumes.isEmpty else { return text + "\n\n  (none)" }

        return text + "\n\n" + volumes.map { volume in
            var line = "  \(Self.oneLine(volume.mountPoint))\n      \(volume.fileSystem) on \(Self.oneLine(volume.device))"
            line += volume.isLocal ? "" : " · network"
            line += volume.isReadOnly ? " · read-only" : ""
            if volume.totalBytes > 0 {
                let share = Double(volume.availableBytes) / Double(volume.totalBytes) * 100
                line += "\n      \(Self.bytes(volume.totalBytes)) total · \(Self.bytes(volume.availableBytes)) available (\(String(format: "%.0f", share))%)"
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: Connections

    public struct SocketRow: Sendable {
        public var socket: SocketRecord
        public var processName: String

        public init(socket: SocketRecord, processName: String) {
            self.socket = socket
            self.processName = processName
        }
    }

    public func connections(rows: [SocketRow], matching: Int, readableProcesses: Int, visibleProcesses: Int) -> String {
        var text = "Sockets: \(matching) matching, from \(readableProcesses) of \(visibleProcesses) processes."
        if readableProcesses < visibleProcesses {
            text += " Sockets of other users' processes and of the system are not visible without root."
        }
        guard !rows.isEmpty else { return text + "\n\n  (none)" }
        text += "\nShowing \(rows.count).\n\n"
        text += "  " + Self.pad("PROTO", to: 6) + Self.pad("LOCAL", to: 30) + Self.pad("REMOTE", to: 30)
            + Self.pad("STATE", to: 13) + Self.padLeft("PID", to: 7) + "  PROCESS\n"
        text += rows.map { row in
            let socket = row.socket
            let remote = socket.remotePort == 0 ? "-" : "\(socket.remoteAddress):\(socket.remotePort)"
            return "  " + Self.pad(socket.transport.rawValue.uppercased(), to: 6)
                + Self.pad("\(socket.localAddress):\(socket.localPort)", to: 30) + Self.pad(remote, to: 30)
                + Self.pad(socket.state ?? "-", to: 13) + Self.padLeft(String(socket.pid), to: 7)
                + "  " + Self.oneLine(row.processName)
        }.joined(separator: "\n")
        return text
    }

    // MARK: Status

    public func status(
        version: String, binaryPath: String, processID: Int32, osVersion: String?,
        visibleProcesses: Int?, readableProcesses: Int?
    ) -> String {
        var text = "System server \(version): ready.\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("process", "pid \(processID)"),
            ("macOS", osVersion),
            ("processes", visibleProcesses.map { "\($0) visible" }),
            (
                "readable",
                readableProcesses.map {
                    "\($0) with CPU and memory counters (the rest belong to other users or the system)"
                }
            ),
        ])
        text += """


            This server reads the process table, CPU and memory counters, network interface \
            counters, mounted volumes and open sockets. It reads no file contents, makes no \
            network connection and changes nothing.

            It runs as the person who started it, and macOS only lets an ordinary process read \
            the counters of processes owned by the same user. That limit is a fact about the \
            machine, not a fault: rows for other processes show n/a.
            """
        return text
    }
}
