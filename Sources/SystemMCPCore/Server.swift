import Foundation

public enum SystemMCPServer {

    public static let name = "apple-system-mcp"
    public static let version = "1.1.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that every percentage is a two-reading measurement, and what an ordinary
    /// process is and is not allowed to read.
    public static let instructions = """
        Reads the state of this Mac: processes, CPU, memory, network interfaces, mounted \
        volumes, open sockets, the battery and storage activity, through the system's own \
        interfaces (libproc, sysctl, Mach, getifaddrs, getfsstat, IOKit). No file contents, no \
        network connection, and nothing is ever changed, stopped or signalled.

        Start with system_overview for the machine as a whole, or system_processes for \
        what is using it. system_process inspects one pid, system_connections finds which \
        process owns a port, system_network and system_volumes cover traffic and disk space, \
        system_battery reports the power source and battery, and system_disks the read and \
        write activity of each drive.

        TWO READINGS PER PERCENTAGE. CPU use, a process's CPU % and network and disk rates \
        are measured between two readings taken sample_ms apart. Each tool takes both itself, \
        so those calls take at least that long (default 500 ms, up to 5000). A longer \
        sample smooths bursts. CPU % is of ONE core: 100 is one core busy, 400 is four.

        WHAT AN ORDINARY PROCESS MAY READ. This server runs as the person who started \
        it. macOS lets such a process list every process with its name, path, owner and \
        parent, but only read the CPU, memory, threads, disk, descriptors and sockets of \
        processes owned by the same user. Everything else shows n/a, and listings say how \
        many rows are affected. That is a property of the machine, not a fault, and not \
        something to work around. system_status reports the split.

        EVERY CALL IS BOUNDED. A call that has not finished after 30 seconds is abandoned \
        and answered with an error saying so; nothing is changed, because nothing is ever \
        written. Retry with a lower sample_ms or a narrower filter.

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
    ///
    /// stdout is the JSON-RPC stream and carries nothing else: a stray line there breaks
    /// every response after it. Diagnostics go to stderr.
    public static func run(source: any SystemSource = DarwinSystemSource()) async {
        let handler = MCPHandler(tools: SystemTools(source: source))
        Diagnostics.started(version: version)
        await serve(
            lines: FileHandle.standardInput.bytes.lines, handler: handler,
            write: { reply in
                // One write per line, so concurrent replies cannot interleave halves of
                // lines. `try?`: the throwing overload reports a closed pipe as an error,
                // where the plain `write(_:)` raises an exception Swift cannot catch.
                try? FileHandle.standardOutput.write(contentsOf: Data((reply + "\n").utf8))
            })
    }
}
