import Foundation

/// Turns one line of JSON-RPC 2.0 into at most one line of reply.
///
/// This is the whole of the Model Context Protocol the server needs over stdio: `initialize`,
/// `ping`, `tools/list` and `tools/call`, one JSON message per line. It takes and returns
/// text so the tests drive it without a pipe.
public struct MCPHandler: Sendable {

    /// Newest first. A client asking for one of these gets it back; any other request is
    /// answered with the newest, and the client decides whether it can speak that.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let tools: SystemTools
    private let name: String
    private let version: String
    private let instructions: String

    public init(
        tools: SystemTools, name: String = SystemMCPServer.name,
        version: String = SystemMCPServer.version, instructions: String = SystemMCPServer.instructions
    ) {
        self.tools = tools
        self.name = name
        self.version = version
        self.instructions = instructions
    }

    private enum Failure {
        static let parse = (code: -32700, message: "Parse error")
        static let invalidRequest = (code: -32600, message: "Invalid request")
        static let methodNotFound = (code: -32601, message: "Method not found")
        static let invalidParameters = (code: -32602, message: "Invalid params")
    }

    /// `nil` for a notification or a client's own response, which are never answered.
    public func respond(to line: String) async -> String? {
        guard let message = try? JSONDecoder().decode(Value.self, from: Data(line.utf8)) else {
            return Self.encode(error: Failure.parse, id: .null)
        }
        guard let fields = message.objectValue else {
            return Self.encode(error: Failure.invalidRequest, id: .null)
        }
        // A message with no method is the client answering something; this server asks
        // nothing, so there is nothing to do with it.
        guard let method = fields["method"]?.stringValue else {
            return fields["id"] == nil ? Self.encode(error: Failure.invalidRequest, id: .null) : nil
        }
        // No id means a notification: it must not be answered, even when it is unknown.
        guard let id = fields["id"] else { return nil }

        let parameters = fields["params"]?.objectValue
        switch method {
        case "initialize":
            return Self.encode(result: initialize(parameters), id: id)
        case "ping":
            return Self.encode(result: .object([:]), id: id)
        case "tools/list":
            return Self.encode(
                result: .object(["tools": .array(ToolCatalog.all().map(\.json))]), id: id)
        case "tools/call":
            guard let toolName = parameters?["name"]?.stringValue else {
                return Self.encode(error: Failure.invalidParameters, id: id)
            }
            let output = await tools.handle(
                ToolCall(name: toolName, arguments: parameters?["arguments"]?.objectValue))
            return Self.encode(
                result: .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(output.text)])
                    ]),
                    "isError": .bool(output.isError),
                ]), id: id)
        default:
            return Self.encode(error: Failure.methodNotFound, id: id)
        }
    }

    private func initialize(_ parameters: [String: Value]?) -> Value {
        let requested = parameters?["protocolVersion"]?.stringValue ?? ""
        let negotiated = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
        return .object([
            "protocolVersion": .string(negotiated),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object(["name": .string(name), "version": .string(version)]),
            "instructions": .string(instructions),
        ])
    }

    private static func encode(result: Value, id: Value) -> String? {
        line(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private static func encode(error: (code: Int, message: String), id: Value) -> String? {
        line([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(error.code), "message": .string(error.message)]),
        ])
    }

    /// JSONEncoder emits no raw newline unless asked to pretty-print, and escapes the ones
    /// inside strings, so a message is always exactly one line.
    private static func line(_ fields: [String: Value]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(Value.object(fields))).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Reads requests until the input ends, answering each on its own task so a slow or stuck
/// call never holds up the ones behind it. Returns once every answer has been written.
public func serve<Lines: AsyncSequence>(
    lines: Lines, handler: MCPHandler, write: @escaping @Sendable (String) -> Void
) async where Lines.Element == String {
    await withTaskGroup(of: Void.self) { group in
        do {
            for try await line in lines {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                group.addTask {
                    if let reply = await handler.respond(to: line) { write(reply) }
                }
            }
        } catch {
            // A read error ends the input like end of file does; what was asked is still
            // answered below.
        }
        await group.waitForAll()
    }
}
