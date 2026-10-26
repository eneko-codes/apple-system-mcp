import Foundation
import MCP

public enum SystemMCPServer {

    public static let name = "apple-system-mcp"
    public static let version = "1.0.1"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that every percentage is a two-reading measurement, and what an ordinary
    /// process is and is not allowed to read.
    public static let instructions = """
        Reads the state of this Mac: processes, CPU, memory, network interfaces, mounted \
        volumes and open sockets, through the system's own C interfaces (libproc, sysctl, \
        Mach, getifaddrs, getfsstat). No file contents, no network connection, and nothing \
        is ever changed, stopped or signalled.

        Start with system_overview for the machine as a whole, or system_processes for \
        what is using it. system_process inspects one pid, system_connections finds which \
        process owns a port, system_network and system_volumes cover traffic and disk space.

        TWO READINGS PER PERCENTAGE. CPU use, a process's CPU % and network rates are \
        measured between two readings taken sample_ms apart. Each tool takes both itself, \
        so those calls take at least that long (default 500 ms, up to 5000). A longer \
        sample smooths bursts. CPU % is of ONE core: 100 is one core busy, 400 is four.

        WHAT AN ORDINARY PROCESS MAY READ. This server runs as the person who started \
        it. macOS lets such a process list every process with its name, path, owner and \
        parent, but only read the CPU, memory, threads, disk, descriptors and sockets of \
        processes owned by the same user. Everything else shows n/a, and listings say how \
        many rows are affected. That is a property of the machine, not a fault, and not \
        something to work around. system_status reports the split.

        pids are reused and go stale quickly: list again before using one seen a while ago.

        Command-line arguments are returned only by system_process with \
        include_arguments, because they can hold secrets. Values that look like secrets \
        are masked, best effort and never a guarantee, so treat that output as \
        sensitive. A process's environment is never read.

        Memory 'in use' is an approximation; the memory pressure level is the system's \
        own verdict and the better signal of trouble.

        This server never writes anything and has no way to stop, signal or reprioritise \
        a process.
        """

    /// The source is a parameter so the whole server can be driven by a double. Nothing in
    /// this function reads the machine by itself.
    public static func run(source: any SystemSource = DarwinSystemSource()) async throws {
        let tools = SystemTools(source: source)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all()) }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        Diagnostics.started(version: version)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
