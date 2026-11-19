import Dispatch
import Foundation
import Synchronization
import Testing

@testable import SystemMCPCore

/// The MCP wire protocol, driven as JSON text in and JSON text out against an invented
/// machine. Nothing here touches stdin, stdout or the real system.
@Suite("Protocol")
struct ProtocolTests {

    private func handler(
        source: FakeSystemSource = FakeSystemSource(), timeout: Duration = SystemTools.defaultTimeout
    ) -> MCPHandler {
        MCPHandler(tools: SystemTools(source: source, sleep: { _ in }, timeout: timeout))
    }

    private func decode(_ line: String?) throws -> [String: Value] {
        let text = try #require(line)
        let value = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        return try #require(value.objectValue)
    }

    private func result(_ line: String?) throws -> [String: Value] {
        try #require(try decode(line)["result"]?.objectValue)
    }

    private func errorCode(_ line: String?) throws -> Int? {
        try decode(line)["error"]?.objectValue?["code"]?.intValue
    }

    // MARK: Initialize

    @Test("initialize echoes a protocol version the server supports")
    func initializeEchoesSupportedVersion() async throws {
        for version in ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"] {
            let reply = await handler().respond(
                to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#)
            #expect(try result(reply)["protocolVersion"]?.stringValue == version)
        }
    }

    @Test("initialize answers with the newest version when the client asks for an unknown one")
    func initializeFallsBackToNewest() async throws {
        let reply = await handler().respond(
            to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect(try result(reply)["protocolVersion"]?.stringValue == "2025-11-25")
    }

    @Test("initialize names the server, its tools capability and its instructions")
    func initializeDescribesServer() async throws {
        let reply = await handler().respond(
            to: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let body = try result(reply)
        #expect(body["serverInfo"]?.objectValue?["name"]?.stringValue == SystemMCPServer.name)
        #expect(body["serverInfo"]?.objectValue?["version"]?.stringValue == SystemMCPServer.version)
        #expect(body["instructions"]?.stringValue == SystemMCPServer.instructions)
        #expect(body["capabilities"]?.objectValue?["tools"]?.objectValue?["listChanged"]?.boolValue == false)
    }

    // MARK: Ping, lists and calls

    @Test("ping answers with an empty result")
    func ping() async throws {
        let reply = await handler().respond(to: #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        #expect(try result(reply).isEmpty)
    }

    @Test("tools/list returns every tool with its schema and read-only annotation")
    func toolsList() async throws {
        let reply = await handler().respond(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require(try result(reply)["tools"]?.arrayValue)
        #expect(tools.compactMap { $0.objectValue?["name"]?.stringValue } == ToolCatalog.all().map(\.name))
        for tool in tools {
            let fields = try #require(tool.objectValue)
            #expect(fields["inputSchema"]?.objectValue?["type"]?.stringValue == "object")
            #expect(fields["annotations"]?.objectValue?["readOnlyHint"]?.boolValue == true)
            #expect(fields["description"]?.stringValue?.isEmpty == false)
        }
    }

    @Test("tools/call returns the tool's text as one text content item")
    func toolsCall() async throws {
        let reply = await handler().respond(
            to: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"system_status","arguments":{}}}"#)
        let body = try result(reply)
        #expect(body["isError"]?.boolValue == false)
        let content = try #require(body["content"]?.arrayValue?.first?.objectValue)
        #expect(content["type"]?.stringValue == "text")
        #expect(content["text"]?.stringValue?.contains("ready") == true)
    }

    @Test("An unknown tool is a tool error, not a protocol error")
    func unknownToolIsToolError() async throws {
        let reply = await handler().respond(
            to: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#)
        #expect(try decode(reply)["error"] == nil)
        #expect(try result(reply)["isError"]?.boolValue == true)
    }

    @Test("tools/call without a name is invalid params")
    func callWithoutName() async throws {
        let reply = await handler().respond(
            to: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#)
        #expect(try errorCode(reply) == -32602)
        #expect(try decode(reply)["id"]?.intValue == 5)
    }

    // MARK: Errors and notifications

    @Test("An unknown method with an id is answered as method not found")
    func unknownMethod() async throws {
        let reply = await handler().respond(to: #"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)
        #expect(try errorCode(reply) == -32601)
    }

    @Test("A notification is never answered, known or not")
    func notificationsGetNoReply() async {
        #expect(await handler().respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await handler().respond(to: #"{"jsonrpc":"2.0","method":"notifications/unheard-of"}"#) == nil)
    }

    @Test("A response from the client is ignored")
    func clientResponseIsIgnored() async {
        #expect(await handler().respond(to: #"{"jsonrpc":"2.0","id":1,"result":{}}"#) == nil)
    }

    @Test("Text that is not JSON is a parse error with a null id")
    func parseError() async throws {
        let reply = await handler().respond(to: "{not json")
        #expect(try errorCode(reply) == -32700)
        #expect(try decode(reply)["id"] == .null)
    }

    @Test("A batch or a bare value is an invalid request")
    func invalidRequest() async throws {
        #expect(try errorCode(await handler().respond(to: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)) == -32600)
        #expect(try errorCode(await handler().respond(to: "42")) == -32600)
    }

    @Test("The id comes back as it was sent, string or number")
    func idIsEchoed() async throws {
        let text = await handler().respond(to: #"{"jsonrpc":"2.0","id":"abc-1","method":"ping"}"#)
        #expect(try decode(text)["id"]?.stringValue == "abc-1")
        let number = await handler().respond(to: #"{"jsonrpc":"2.0","id":41,"method":"ping"}"#)
        #expect(try decode(number)["id"]?.intValue == 41)
    }

    @Test("A reply is a single line however many lines the text has")
    func replyIsOneLine() async throws {
        let reply = try #require(
            await handler().respond(
                to: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"system_status"}}"#))
        #expect(!reply.contains("\n"))
        #expect(try result(reply)["content"] != nil)
    }

    // MARK: Serving a stream

    private final class Collected: Sendable {
        private let lines = Mutex<[String]>([])
        var all: [String] { lines.withLock { $0 } }
        func add(_ line: String) { lines.withLock { $0.append(line) } }
    }

    private func ids(_ lines: [String]) throws -> [Int] {
        try lines.compactMap { try decode($0)["id"]?.intValue }
    }

    @Test("Every request in a stream is answered, then serving ends at end of input")
    func serveAnswersAndStops() async throws {
        let collected = Collected()
        let input = AsyncStream<String> { continuation in
            continuation.yield(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
            continuation.yield("")
            continuation.yield(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            continuation.yield(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            continuation.finish()
        }
        await serve(lines: input, handler: handler(), write: { collected.add($0) })
        #expect(try ids(collected.all).sorted() == [1, 2])
    }

    @Test("A call that is stuck does not hold up the ones behind it", .timeLimit(.minutes(1)))
    func stuckCallDoesNotBlockOthers() async throws {
        let gate = DispatchSemaphore(value: 0)
        let source = FakeSystemSource { $0.blockProcessSnapshot = gate }
        defer { gate.signal(); gate.signal() }

        let collected = Collected()
        let input = AsyncStream<String> { continuation in
            continuation.yield(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"system_processes"}}"#)
            continuation.yield(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
            continuation.finish()
        }
        await serve(
            lines: input, handler: handler(source: source, timeout: .milliseconds(300)),
            write: { collected.add($0) })

        // The ping is answered first; the stuck call ends with its time-out error.
        #expect(try ids(collected.all) == [2, 1])
        #expect(try result(collected.all.last)["isError"]?.boolValue == true)
    }

    // MARK: Values

    @Test("JSON values decode to the right case")
    func valueDecoding() throws {
        let value = try JSONDecoder().decode(
            Value.self,
            from: Data(#"{"a":1,"b":2.5,"c":true,"d":null,"e":"x","f":[1,"y"],"g":20.0}"#.utf8))
        let fields = try #require(value.objectValue)
        #expect(fields["a"] == .int(1))
        #expect(fields["b"] == .double(2.5))
        #expect(fields["c"] == .bool(true))
        #expect(fields["d"] == .null)
        #expect(fields["e"] == .string("x"))
        #expect(fields["f"] == .array([.int(1), .string("y")]))
        #expect(fields["g"]?.intValue == 20)
        #expect(fields["b"]?.intValue == nil)
        #expect(fields["a"]?.boolValue == nil)
    }
}
