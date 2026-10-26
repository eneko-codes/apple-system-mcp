import Foundation
import MCP
import Testing

@testable import SystemMCPCore

/// The installer keys on the manifest version alone, so a build whose three version strings
/// disagree is a bug report that describes a build nobody has. Reads this repository's own
/// files, not the machine.
@Suite("Release metadata")
struct VersionTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        let manifestVersion = try #require(try manifest()["version"] as? String)
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(manifestVersion == SystemMCPServer.version)
        #expect(plist["CFBundleShortVersionString"] as? String == SystemMCPServer.version)
    }

    @Test("The manifest name and the plist identifier match the server")
    func namesAgree() throws {
        #expect(try manifest()["name"] as? String == SystemMCPServer.name)
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleName"] as? String == SystemMCPServer.name)
        #expect(plist["CFBundleIdentifier"] as? String == "codes.eneko.\(SystemMCPServer.name)")
    }

    /// A tool missing from the manifest has no permission switch at all, and the manifest
    /// is read before the server has ever run.
    @Test("The manifest lists exactly the tools the server offers")
    func manifestListsEveryTool() throws {
        let listed = try #require(try manifest()["tools"] as? [[String: Any]])
        let manifestNames = listed.compactMap { $0["name"] as? String }
        #expect(Set(manifestNames) == Set(ToolCatalog.all().map(\.name)))
        #expect(manifestNames.count == Set(manifestNames).count)
        for tool in listed {
            #expect((tool["description"] as? String)?.isEmpty == false)
        }
    }

    @Test("The manifest asks for no user configuration, because the server reads none")
    func noUserConfig() throws {
        let manifest = try manifest()
        #expect(manifest["user_config"] == nil)
        let server = try #require(manifest["server"] as? [String: Any])
        let config = try #require(server["mcp_config"] as? [String: Any])
        #expect((config["args"] as? [Any])?.isEmpty == true)
    }

    @Test("The Info.plist declares no usage description, because nothing here is TCC-gated")
    func plistHasNoUsageDescriptions() throws {
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(!plist.keys.contains { $0.hasSuffix("UsageDescription") })
    }
}
