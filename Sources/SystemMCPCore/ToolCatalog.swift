import Foundation
import MCP

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

    public static let sampleRange = 100...5000
    public static let networkSampleRange = 0...5000
    public static let defaultSampleMilliseconds = 500
    public static let defaultNetworkSampleMilliseconds = 1000
    public static let processLimitRange = 1...200
    public static let defaultProcessLimit = 25
    public static let connectionLimitRange = 1...500
    public static let defaultConnectionLimit = 100

    public static let processSortKeys = ["cpu", "memory", "name", "pid"]
    public static let socketStates = ["listening", "established", "all"]
    public static let socketProtocols = ["tcp", "udp", "all"]

    public static func all() -> [Tool] {
        [status, overview, processes, process, network, volumes, connections]
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
            wired, compressed, file cache, free) and swap.

            CPU use is a measurement between two readings taken sample_ms apart, so the \
            call takes at least that long. Memory 'in use' is an approximation: the system \
            documents no exact formula, so the figure is built from app memory, wired and \
            compressed pages and is labelled as such. Pressure is the system's own \
            verdict (normal, warning, critical) and is the better signal of trouble than \
            the amount in use.

            Pass per_core to also list the busy share of each core.
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
            Lists the running processes with CPU %, memory, thread count, owner and name, \
            sorted by cpu, memory, name or pid, optionally filtered by name, owner or \
            parent.

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
                "What to sort by: 'cpu' and 'memory' are descending, 'name' and 'pid' ascending.",
                processSortKeys, default: "cpu"),
            "name_contains": string("Only processes whose name contains this text, ignoring case."),
            "user": string("Only processes owned by this user name, or by this numeric uid."),
            "parent_pid": integer(
                "Only the direct children of this pid.", range: 0...10_000_000),
            "limit": integer(
                "Maximum number of processes to return.", range: processLimitRange,
                default: defaultProcessLimit),
            "sample_ms": integer(sampleHelp, range: sampleRange, default: defaultSampleMilliseconds),
        ]),
        annotations: readOnly)

    static let process = Tool(
        name: processName,
        title: "Inspect one process",
        description: """
            Everything readable about one process by pid: state, executable path, owner, \
            parent, start time, CPU rate and total CPU time, memory footprint, threads, \
            disk bytes read and written, open descriptor count, working directory and \
            children.

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
                "pid": integer("Process id, from system_processes.", range: 0...10_000_000),
                "include_arguments": boolean(
                    "Also return the command-line arguments, with likely secrets masked.",
                    default: false),
                "sample_ms": integer(sampleHelp, range: sampleRange, default: defaultSampleMilliseconds),
            ], required: ["pid"]),
        annotations: readOnly)

    static let network = Tool(
        name: networkName,
        title: "Network interfaces and traffic",
        description: """
            Network interfaces with their addresses and 64-bit cumulative counters of bytes, \
            packets and errors since boot, plus the current rate in each direction when \
            sample_ms is above zero.

            Only interfaces that are up and have an address or traffic are listed unless \
            include_inactive is set. Counters are totals for the interface, not per process: \
            the system offers no per-process traffic figure through this interface.
            """,
        inputSchema: object(properties: [
            "sample_ms": integer(
                "Milliseconds between the two readings a rate needs; 0 returns totals only.",
                range: networkSampleRange, default: defaultNetworkSampleMilliseconds),
            "include_inactive": boolean(
                "Also list interfaces that are down or have no address and no traffic.",
                default: false),
        ]),
        annotations: readOnly)

    static let volumes = Tool(
        name: volumesName,
        title: "Mounted volumes and free space",
        description: """
            Mounted volumes with file system, device, total size and the space an ordinary \
            process may use. System-internal mounts (devfs, autofs, nullfs, devicefs and the \
            helper volumes under /System/Volumes other than Data) are hidden unless \
            include_hidden is set.

            The available figure can differ from the space Finder reports, because Finder \
            also counts purgeable files as available. Reading the list does not wait on a \
            network volume that has stopped answering.
            """,
        inputSchema: object(properties: [
            "include_hidden": boolean("Also list system-internal volumes.", default: false)
        ]),
        annotations: readOnly)

    static let connections = Tool(
        name: connectionsName,
        title: "Open TCP and UDP sockets by process",
        description: """
            Open TCP and UDP sockets with local and remote address, TCP state and the \
            process that owns each. Use it to find which process is listening on a port or \
            which one holds a connection.

            By default only sockets waiting for traffic are listed (TCP in LISTEN, UDP bound \
            to a port with no peer); pass state 'established' or 'all' for the rest. UDP \
            sockets that were created but never bound have no port and are only listed \
            with state 'all'. Filter by pid, by port \
            (matches local or remote) or by protocol.

            What an ordinary process may read: sockets are only visible for processes of \
            the same user, so a service run by root or another user does not appear. The \
            header says how many processes were readable.
            """,
        inputSchema: object(properties: [
            "state": choice(
                "'listening' (default): sockets waiting for traffic; 'established': TCP connections in use; 'all'.",
                socketStates, default: "listening"),
            "protocol": choice("Transport to list.", socketProtocols, default: "all"),
            "pid": integer(
                "Only the sockets of this process.", range: 0...10_000_000),
            "port": integer(
                "Only sockets whose local or remote port is this.", range: 1...65_535),
            "limit": integer(
                "Maximum number of sockets to return.", range: connectionLimitRange,
                default: defaultConnectionLimit),
        ]),
        annotations: readOnly)
}
