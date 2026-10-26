import Foundation
import MCP
import Testing

@testable import SystemMCPCore

/// Checks on the advertised surface itself. None of these reads the machine.
@Suite("Catalogue")
struct CatalogueTests {

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union such as
    /// `["string", "null"]` and hands the model a bare `{}` in its place. The fault is
    /// invisible until a caller happens to use that field, so the whole catalogue is
    /// walked here rather than trusted to review.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    @Test("Every tool is read-only and closed to the outside world")
    func everyToolIsReadOnly() {
        for tool in ToolCatalog.all() {
            #expect(tool.annotations.readOnlyHint == true, "\(tool.name) is mis-annotated")
            #expect(tool.annotations.destructiveHint == false, "\(tool.name) is mis-annotated")
            #expect(tool.annotations.openWorldHint == false, "\(tool.name) is mis-annotated")
        }
    }

    @Test("Every tool name is prefixed system_, so its permission switch is recognisable")
    func namesArePrefixed() {
        for tool in ToolCatalog.all() {
            #expect(tool.name.hasPrefix("system_"))
        }
    }

    @Test("Filters advertise no default, because omitting one means no filter")
    func filtersHaveNoDefault() {
        let filters: [(tool: String, property: String)] = [
            (ToolCatalog.processesName, "parent_pid"), (ToolCatalog.connectionsName, "pid"),
            (ToolCatalog.connectionsName, "port"), (ToolCatalog.processName, "pid"),
        ]
        for (name, property) in filters {
            let tool = ToolCatalog.all().first { $0.name == name }
            guard case .object(let schema)? = tool?.inputSchema,
                case .object(let properties)? = schema["properties"],
                case .object(let definition)? = properties[property]
            else {
                Issue.record("\(name).\(property) is missing")
                continue
            }
            #expect(definition["default"] == nil, "\(name).\(property) advertises a default")
        }
    }

    @Test("pid is the one required argument, and only on system_process")
    func requiredArguments() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema else { continue }
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(required == (tool.name == ToolCatalog.processName ? ["pid"] : []))
        }
    }

    /// Everything the model reads at runtime. A server documents itself and nothing else:
    /// naming another server or tool here makes the model call something that is not there.
    @Test("No shipped string names another server")
    func noCrossReferences() {
        var shipped = [SystemMCPServer.instructions]
        for tool in ToolCatalog.all() {
            shipped.append(tool.description ?? "")
            if case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            {
                for case .object(let definition) in properties.values {
                    shipped.append(definition["description"]?.stringValue ?? "")
                }
            }
        }
        shipped.append(ToolError.processNotFound(pid: 1).message)
        shipped.append(ToolError.systemFailure(function: "f", code: 1).message)
        for text in shipped {
            #expect(!text.contains("-mcp"), "a shipped string names another server")
        }
    }

    @Test("The server instructions mention every tool, so none is undiscoverable")
    func instructionsCoverTheTools() {
        for tool in ToolCatalog.all() where tool.name != ToolCatalog.statusName {
            #expect(SystemMCPServer.instructions.contains(tool.name), "\(tool.name) is not in the instructions")
        }
        #expect(SystemMCPServer.instructions.contains(ToolCatalog.statusName))
    }
}
