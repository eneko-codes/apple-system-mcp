// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-system-mcp",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        .target(
            name: "SystemMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "apple-system-mcp",
            dependencies: ["SystemMCPCore"],
            // The embedded Info.plist gives the binary its bundle identifier and version,
            // which the code signature's designated requirement quotes. This server reads
            // no TCC-protected location, so the plist declares no usage descriptions.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "SystemMCPCoreTests", dependencies: ["SystemMCPCore"]),
    ]
)
