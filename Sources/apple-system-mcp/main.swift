import SystemMCPCore

// Launcher only. Everything testable lives in SystemMCPCore, which the test target
// imports; an executable target cannot be imported. This server takes no settings.
await SystemMCPServer.run()
