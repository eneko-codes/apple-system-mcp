import Foundation

public enum ToolError: Error, Equatable {
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case processNotFound(pid: Int32)
    case systemFailure(function: String, code: Int32)

    public var message: String {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

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
