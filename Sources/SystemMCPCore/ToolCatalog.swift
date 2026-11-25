import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
public enum ToolCatalog {

    public static let statusName = "system_status"
    public static let overviewName = "system_overview"
    public static let processesName = "system_processes"
    public static let processName = "system_process"
    public static let networkName = "system_network"
    public static let volumesName = "system_volumes"
    public static let connectionsName = "system_connections"
    public static let batteryName = "system_battery"
    public static let disksName = "system_disks"

    /// The longest wait between two readings, the same for every tool that takes two.
    public static let longestSampleMilliseconds = 5000
    public static let sampleRange = 100...longestSampleMilliseconds
    public static let networkSampleRange = 0...longestSampleMilliseconds
    public static let defaultSampleMilliseconds = 500
    public static let defaultNetworkSampleMilliseconds = 1000
    public static let diskSampleRange = 0...longestSampleMilliseconds
    public static let defaultDiskSampleMilliseconds = 1000

    /// Identifiers. A value outside one of these is refused, never moved.
    public static let pidRange = 0...10_000_000
    public static let portRange = 1...65_535

    // Pages. Each maximum is a number of rows of ordinary width that fits
    // `ToolStandard.longestResult` with room to spare, and each default makes a call with
    // no argument about `ToolStandard.usualPage` or less. `BoundsTests` renders a full page
    // of the widest ordinary rows of every listing to hold both to that.
    public static let offsetRange = 0...10_000_000
    public static let processLimitRange = 1...200
    public static let defaultProcessLimit = 25
    public static let connectionLimitRange = 1...200
    public static let defaultConnectionLimit = 50
    public static let interfaceLimitRange = 1...100
    public static let defaultInterfaceLimit = 25
    public static let volumeLimitRange = 1...200
    public static let defaultVolumeLimit = 50
    public static let diskLimitRange = 1...100
    public static let defaultDiskLimit = 25
    public static let childLimitRange = 1...100
    public static let defaultChildLimit = 10

    /// The window on a process's argument listing. The maximum is half the longest result,
    /// so a window of ordinary text leaves room for the rest of the report;
    /// `Format.fitting` shrinks one whose characters take more UTF-16 units than that.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    public static let processSortKeys = ["cpu", "memory", "name", "pid"]
    public static let socketStates = ["listening", "established", "all"]
    public static let socketProtocols = ["tcp", "udp", "all"]

    public static func all() -> [Tool] {
        [status, overview, processes, process, network, volumes, connections, battery, disks]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is the single string `"string"`, never `["string", "null"]`. Claude
    /// Desktop's schema sanitiser drops a property whose `type` is a union and hands the
    /// model a bare `{}` in its place.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    /// A `default` is advertised only where omitting the argument really means that value.
    /// A filter has none: leaving it out means "no filter", and a default would read as
    /// a filter being applied.
    private static func integer(
        _ description: String, range: ClosedRange<Int>, default def: Int? = nil
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
        ]
        if let def { schema["default"] = .int(def) }
        return .object(schema)
    }

    private static func boolean(_ description: String, default def: Bool) -> Value {
        .object([
            "type": .string("boolean"), "description": .string(description),
            "default": .bool(def),
        ])
    }

    private static func choice(_ description: String, _ values: [String], default def: String)
        -> Value
    {
        .object([
            "type": .string("string"), "enum": .array(values.map { .string($0) }),
            "default": .string(def), "description": .string(description),
        ])
    }

    private static let sampleHelp = """
        Milliseconds to wait between the two readings a rate needs. A longer sample smooths \
        short bursts; the call takes at least this long.
        """

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: def)
    }

    private static let offset = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, range: offsetRange, default: 0)

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "System server status",
        description: """
            Reports that this server is running and how much of the machine it can read: \
            how many processes it can see and for how many of them it can read CPU and \
            memory. Changes nothing.

            Call it first when a result shows n/a and you need to know whether that is a \
            limit of this machine or a fault. It will report that processes owned by other \
            users or by the system cannot be read by an ordinary process.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly)

    static let overview = Tool(
        name: overviewName,
        title: "System overview",
        description: """
            The machine as a whole: macOS version and uptime, chip and core layout, CPU \
            use measured over a short sample, load average, memory (in use, pressure, \
            wired, compressed, file cache, free) and swap. The busy share of each core is \
            left out unless per_core is set.

            CPU use is a measurement between two readings taken sample_ms apart, so the \
            call takes at least that long. Memory 'in use' is an approximation: the system \
            documents no exact formula, so the figure is built from app memory, wired and \
            compressed pages and is labelled as such. Pressure is the system's own \
            verdict (normal, warning, critical) and is the better signal of trouble than \
            the amount in use.
            """,
        inputSchema: object(properties: [
            "sample_ms": integer(sampleHelp, range: sampleRange, default: defaultSampleMilliseconds),
            "per_core": boolean("Also list the busy share of every core.", default: false),
        ]),
        annotations: readOnly)

    static let processes = Tool(
        name: processesName,
        title: "List processes with CPU and memory",
        description: """
            Lists the running processes, \(defaultProcessLimit) to a page, the ones using the \
            most CPU first, each with pid, CPU %, memory, thread count, owner and name. When \
            more match than the page holds, the first lines of the result say how many \
            there are and the offset of the next page: pass limit (up to \
            \(processLimitRange.upperBound)) and offset for the rest. sort_by orders by \
            memory, name or pid instead; name_contains, user and parent_pid filter.

            Every call takes a new sample, so the CPU order can shift between two pages. \
            Sort by pid or name when every process has to be seen exactly once.

            CPU % is measured between two readings sample_ms apart and is a percentage of \
            ONE core: 100 is one core fully busy, and a process using four cores can show \
            400. Memory is the physical footprint charged to the process.

            What an ordinary process may read: every process is listed with its name, owner \
            and pid, but CPU, memory and threads are only readable for processes of the same \
            user. The rest show n/a and sort after the readable ones; the header says how \
            many. That is how macOS works for a process that is not root, not a fault.

            pids are reused and go stale quickly. Use the pid from this listing right away \
            with system_process.
            """,
        inputSchema: object(properties: [
            "sort_by": choice(
                "What to order by: 'cpu' and 'memory' are descending, 'name' and 'pid' ascending. Ties go by pid.",
                processSortKeys, default: "cpu"),
            "name_contains": string("Only processes whose name contains this text, ignoring case."),
            "user": string("Only processes owned by this user name, or by this numeric uid."),
            "parent_pid": integer("Only the direct children of this pid.", range: pidRange),
            "limit": limit("processes", range: processLimitRange, default: defaultProcessLimit),
            "offset": offset,
            "sample_ms": integer(sampleHelp, range: sampleRange, default: defaultSampleMilliseconds),
        ]),
        annotations: readOnly)

    static let process = Tool(
        name: processName,
        title: "Inspect one process",
        description: """
            Everything readable about one process by pid: state, executable path, owner, \
            parent, start time, CPU rate and total CPU time, memory footprint, threads, \
            disk bytes read and written, open descriptor count, working directory and its \
            first \(defaultChildLimit) children by pid. Command-line arguments are left out \
            unless include_arguments is set.

            The first lines of the result say what it does not hold and how to get it: \
            pass limit (up to \(childLimitRange.upperBound)) and offset for more children, \
            and character_offset and max_characters (default \(defaultMaxCharacters), up to \
            \(maxCharactersRange.upperBound)) to read a long argument listing one window at \
            a time.

            CPU rate is measured over sample_ms and is a percentage of one core. For a \
            process of another user or of the system only the identity fields are \
            readable; usage shows as not readable because macOS withholds it from a process \
            that is not root.

            Command-line arguments are returned only with include_arguments, because they \
            can contain secrets such as tokens and passwords passed on the command line. \
            Values that look like secrets are masked, best effort and never a guarantee, so \
            treat the result as sensitive. The process environment is never read.
            """,
        inputSchema: object(
            properties: [
                "pid": integer("Process id, from system_processes.", range: pidRange),
                "include_arguments": boolean(
                    "Also return the command-line arguments, with likely secrets masked.",
                    default: false),
                "limit": limit("children", range: childLimitRange, default: defaultChildLimit),
                "offset": integer(
                    """
                    Number of children to skip. A result that does not list every child \
                    says, in its first lines, the offset to pass for the next page.
                    """, range: offsetRange, default: 0),
                "character_offset": integer(
                    """
                    With include_arguments: number of characters of the argument listing to \
                    skip. A result that does not hold all of it says, in its first lines, \
                    the value to pass for the rest.
                    """, range: offsetRange, default: 0),
                "max_characters": integer(
                    "With include_arguments: the most characters of the argument listing to return.",
                    range: maxCharactersRange, default: defaultMaxCharacters),
                "sample_ms": integer(sampleHelp, range: sampleRange, default: defaultSampleMilliseconds),
            ], required: ["pid"]),
        annotations: readOnly)

    static let network = Tool(
        name: networkName,
        title: "Network interfaces and traffic",
        description: """
            Network interfaces, \(defaultInterfaceLimit) to a page in name order, with their \
            addresses and 64-bit cumulative counters of bytes, packets and errors since \
            boot, plus the current rate in each direction when sample_ms is above zero. \
            Interfaces that are down, or have no address and no traffic, are left out and \
            counted; include_inactive lists them. When there are more than the page holds, \
            the first lines of the result give the offset of the next page: pass limit (up \
            to \(interfaceLimitRange.upperBound)) and offset.

            Counters are totals for the interface, not per process: \
            the system offers no per-process traffic figure through this interface.
            """,
        inputSchema: object(properties: [
            "sample_ms": integer(
                "Milliseconds between the two readings a rate needs; 0 returns totals only.",
                range: networkSampleRange, default: defaultNetworkSampleMilliseconds),
            "include_inactive": boolean(
                "Also list interfaces that are down or have no address and no traffic.",
                default: false),
            "limit": limit("interfaces", range: interfaceLimitRange, default: defaultInterfaceLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let volumes = Tool(
        name: volumesName,
        title: "Mounted volumes and free space",
        description: """
            Mounted volumes, \(defaultVolumeLimit) to a page in mount point order, with file \
            system, device, total size and the space an ordinary process may use. \
            System-internal mounts (devfs, autofs, nullfs, devicefs and the helper volumes \
            under /System/Volumes other than Data) are left out and counted; include_hidden \
            lists them. When there are more than the page holds, the first lines of the \
            result give the offset of the next page: pass limit (up to \
            \(volumeLimitRange.upperBound)) and offset.

            The available figure can differ from the space Finder reports, because Finder \
            also counts purgeable files as available. Reading the list does not wait on a \
            network volume that has stopped answering.
            """,
        inputSchema: object(properties: [
            "include_hidden": boolean("Also list system-internal volumes.", default: false),
            "limit": limit("volumes", range: volumeLimitRange, default: defaultVolumeLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let connections = Tool(
        name: connectionsName,
        title: "Open TCP and UDP sockets by process",
        description: """
            Open TCP and UDP sockets waiting for traffic, \(defaultConnectionLimit) to a page \
            in local port order, each with local and remote address, TCP state and the \
            process that owns it. Use it to find which process is listening on a port or \
            which one holds a connection. Connections in use are left out unless state is \
            'established' or 'all'. When more match than the page holds, the first lines of \
            the result say how many there are and the offset of the next page: pass limit \
            (up to \(connectionLimitRange.upperBound)) and offset.

            Waiting for traffic means TCP in LISTEN, or UDP bound to a port with no peer. \
            UDP sockets that were created but never bound have no port and are only listed \
            with state 'all'. Filter by pid, by port (matches local or remote) or by \
            protocol.

            What an ordinary process may read: sockets are only visible for processes of \
            the same user, so a service run by root or another user does not appear. The \
            header says how many processes were readable.
            """,
        inputSchema: object(properties: [
            "state": choice(
                "'listening' (default): sockets waiting for traffic; 'established': TCP connections in use; 'all'.",
                socketStates, default: "listening"),
            "protocol": choice("Transport to list.", socketProtocols, default: "all"),
            "pid": integer("Only the sockets of this process.", range: pidRange),
            "port": integer("Only sockets whose local or remote port is this.", range: portRange),
            "limit": limit("sockets", range: connectionLimitRange, default: defaultConnectionLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let battery = Tool(
        name: batteryName,
        title: "Battery and power source",
        description: """
            What the Mac is running on (mains, battery or a UPS) and, for each battery or \
            UPS: charge level, whether it is charging, discharging or full, the time to \
            empty or to full the system estimates, its health verdict and, where the \
            system publishes them, temperature, voltage and current.

            A Mac with no battery (a desktop) answers that none was found; that is not an \
            error. A time of "still being calculated" is the system's own state right \
            after a change of power source, not a fault. The battery's serial number is \
            never returned, and cycle count is not available through the system's \
            documented power-source interface.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly)

    static let disks = Tool(
        name: disksName,
        title: "Disk throughput and latency",
        description: """
            Read and write activity of each storage driver (the internal drive, an \
            external disk, a mounted disk image), \(defaultDiskLimit) to a page in name \
            order: bytes and operations since the driver started, and, measured between two \
            readings sample_ms apart, bytes per second, operations per second and the \
            average time one operation took. When there are more than the page holds, the \
            first lines of the result give the offset of the next page: pass limit (up to \
            \(diskLimitRange.upperBound)) and offset.

            A drive is named by its BSD name (disk0), never by model or serial number. \
            These are whole-drive counters: the system offers no per-process or per-file \
            figure through this interface. For free space on a volume use system_volumes. \
            sample_ms 0 returns totals only.
            """,
        inputSchema: object(properties: [
            "sample_ms": integer(
                "Milliseconds between the two readings a rate needs; 0 returns totals only.",
                range: diskSampleRange, default: defaultDiskSampleMilliseconds),
            "limit": limit("storage drivers", range: diskLimitRange, default: defaultDiskLimit),
            "offset": offset,
        ]),
        annotations: readOnly)
}
