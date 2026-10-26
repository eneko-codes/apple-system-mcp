import Darwin
import Foundation

/// Thin wrappers over the C calls `DarwinSystemSource` makes, so the unit conversions and
/// buffer handling that are easy to get subtly wrong live in one place.
enum SystemCalls {

    // MARK: Mach time

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Mach ticks are not nanoseconds: on Apple silicon one tick is 125/3 ns. libproc
    /// reports CPU time in ticks, so skipping this makes every process look about 41 times
    /// less busy than it is.
    static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        let numerator = UInt64(timebase.numer)
        let denominator = UInt64(max(timebase.denom, 1))
        let (high, low) = ticks.multipliedFullWidth(by: numerator)
        // dividingFullWidth traps when the quotient does not fit; saturate instead.
        guard high < denominator else { return .max }
        return denominator.dividingFullWidth((high, low)).quotient
    }

    // MARK: Strings

    /// A fixed-size C `char` array arrives in Swift as a tuple; read it up to the first NUL.
    static func string<Tuple>(fromCArray tuple: Tuple) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// A NUL-terminated buffer a C function filled in.
    static func string(fromCChars characters: [CChar]) -> String {
        String(
            decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: sysctl

    static func sysctlInteger<Value: FixedWidthInteger>(_ name: String) throws -> Value {
        var value: Value = 0
        var size = MemoryLayout<Value>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            throw SystemSourceError.callFailed(function: "sysctlbyname(\(name))", code: errno)
        }
        return value
    }

    static func sysctlString(_ name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            throw SystemSourceError.callFailed(function: "sysctlbyname(\(name))", code: errno)
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            throw SystemSourceError.callFailed(function: "sysctlbyname(\(name))", code: errno)
        }
        return string(fromCChars: buffer)
    }

    static func sysctlStructure<Value: BitwiseCopyable>(_ name: String, initial: Value) throws
        -> Value
    {
        var value = initial
        var size = MemoryLayout<Value>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Value>.size
        else {
            throw SystemSourceError.callFailed(function: "sysctlbyname(\(name))", code: errno)
        }
        return value
    }

    // MARK: Counter arithmetic

    /// Difference between two readings of a 32-bit counter that is allowed to wrap. Scheduler
    /// ticks are 32 bits per core and wrap after roughly 500 days of uptime.
    static func wrappingDelta(from earlier: UInt64, to later: UInt64) -> UInt64 {
        later >= earlier ? later - earlier : later + (1 << 32) - earlier
    }
}
