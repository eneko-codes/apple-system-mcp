import Foundation

public enum ToolError: Error, Equatable {
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case unknownTool(String)
    case processNotFound(pid: Int32)
    case systemFailure(function: String, code: Int32)
    case timedOut(seconds: Int)

    /// How much of a caller's own text an error repeats. An error is read by the model,
    /// and a long argument echoed whole would crowd out what was wrong with it.
    static let echoWidth = 80

    /// `text` as an error may repeat it: at most `echoWidth` characters.
    static func echo(_ text: String) -> String {
        text.count > echoWidth ? String(text.prefix(echoWidth)) + "…" : text
    }

    public var message: String {
        switch self {
        case .timedOut(let seconds):
            return """
                The call did not finish within \(seconds) seconds and was abandoned. This \
                server only reads, so nothing was changed.

                A system call may be waiting on something that is not answering. Try again, \
                with a lower sample_ms or a narrower filter; system_status says whether the \
                server still answers at all.
                """

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .unknownTool(let name):
            return "'\(Self.echo(name))' is not a tool of this server."

        case .processNotFound(let pid):
            return """
                No process with pid \(pid) exists right now.

                Process ids are reused and go stale quickly: the process may have exited \
                since system_processes listed it. List again and use the pid it shows now.
                """

        case .systemFailure(let function, let code):
            return """
                The system call \(function) failed (error code \(code)).

                This server only reads, so nothing was changed. If it keeps failing, \
                system_status reports what this server can currently read.
                """
        }
    }
}
