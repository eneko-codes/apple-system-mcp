import Foundation

/// The only door to the machine. Every tool reads through this protocol, which is what
/// lets the whole server run against an in-memory double with no process table, no
/// kernel and no permission involved.
public protocol SystemSource: Sendable {
    /// Monotonic clock in nanoseconds. Counts time spent asleep, so a sample taken across
    /// a suspend does not report a flattering CPU percentage.
    func uptimeNanoseconds() -> UInt64

    func processSnapshot() throws -> ProcessSnapshot
    /// `nil` when the process has already exited.
    func processDetail(pid: Int32) throws -> ProcessDetail?
    /// Command-line arguments only. The environment is never read. `nil` when the caller
    /// is not allowed to read this process or it has exited.
    func arguments(pid: Int32) throws -> [String]?
    func userName(userID: UInt32) -> String?

    func coreTicks() throws -> [CoreTicks]
    func memory() throws -> MemorySnapshot
    func memoryPressure() throws -> MemoryPressure
    func swap() throws -> SwapUsage
    func hardware() throws -> HardwareInfo
    func kernel() throws -> KernelInfo
    func loadAverage() throws -> LoadAverage

    func networkSnapshot() throws -> NetworkSnapshot
    func volumes() throws -> [Volume]
    func sockets() throws -> [SocketRecord]
}

/// A failed system call. Carries the function and the error code, never anything that
/// came from a request, so it can be shown and logged as is.
public enum SystemSourceError: Error, Equatable {
    case callFailed(function: String, code: Int32)
    case unexpectedShape(function: String)
}
