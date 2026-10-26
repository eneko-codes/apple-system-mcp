import Foundation

/// The arithmetic behind every percentage and rate. Each one needs two readings taken a
/// known time apart, so these take both and the elapsed time, and nothing else.
public enum Metrics {

    public struct CPUBreakdown: Sendable, Equatable {
        public var userPercent: Double
        public var systemPercent: Double
        public var idlePercent: Double
        public var busyPercent: Double { userPercent + systemPercent }
    }

    /// Share of one core's time spent in each state between two readings. `nice` ticks are
    /// user time at a lower priority and are counted as user. `nil` when no tick elapsed,
    /// which happens if the two readings are too close together.
    public static func cpuBreakdown(from before: CoreTicks, to after: CoreTicks) -> CPUBreakdown? {
        cpuBreakdown(from: [before], to: [after])
    }

    /// Every core together, weighted by ticks rather than averaging per-core percentages.
    /// Each core's counter is differenced on its own first, because each wraps on its own.
    /// `nil` when the two readings cover a different number of cores.
    public static func cpuBreakdown(from before: [CoreTicks], to after: [CoreTicks]) -> CPUBreakdown? {
        guard before.count == after.count, !before.isEmpty else { return nil }
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        for (earlier, later) in zip(before, after) {
            user += SystemCalls.wrappingDelta(from: earlier.user, to: later.user)
                + SystemCalls.wrappingDelta(from: earlier.nice, to: later.nice)
            system += SystemCalls.wrappingDelta(from: earlier.system, to: later.system)
            idle += SystemCalls.wrappingDelta(from: earlier.idle, to: later.idle)
        }
        let total = user + system + idle
        guard total > 0 else { return nil }
        let scale = 100 / Double(total)
        return CPUBreakdown(
            userPercent: Double(user) * scale, systemPercent: Double(system) * scale,
            idlePercent: Double(idle) * scale)
    }

    /// CPU time used divided by wall time, as a percentage of ONE core: 100 means one core
    /// fully busy and a process running on four cores can reach 400.
    ///
    /// `nil` when either reading is missing, or when the counter went backwards, which is
    /// how a recycled pid shows up.
    public static func processCPUPercent(
        before: ProcessUsage?, after: ProcessUsage?, elapsedNanoseconds: UInt64
    ) -> Double? {
        guard let before, let after, elapsedNanoseconds > 0,
            after.cpuTimeNanoseconds >= before.cpuTimeNanoseconds
        else { return nil }
        let used = after.cpuTimeNanoseconds - before.cpuTimeNanoseconds
        return Double(used) / Double(elapsedNanoseconds) * 100
    }

    /// Bytes per second between two cumulative counters. `nil` if the counter went
    /// backwards, which happens when an interface is reset.
    public static func bytesPerSecond(
        before: UInt64, after: UInt64, elapsedNanoseconds: UInt64
    ) -> Double? {
        guard after >= before, elapsedNanoseconds > 0 else { return nil }
        return Double(after - before) / (Double(elapsedNanoseconds) / 1_000_000_000)
    }
}
