import Foundation
import SystemMCPCore

// Launcher only. Everything testable lives in SystemMCPCore, which the test target
// imports; an executable target cannot be imported. This server takes no settings.
do {
    try await SystemMCPServer.run()
} catch {
    // Exiting 0 here would be indistinguishable from a clean shutdown, which is how a
    // server disappears mid-session with nothing to show for it.
    Diagnostics.fatal(error)
    exit(1)
}
