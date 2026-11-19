import Foundation
import IOKit

/// Storage activity from `IOBlockStorageDriver`, whose `Statistics` dictionary and key names
/// are documented in `IOKit/storage/IOBlockStorageDriver.h`. Each driver is named by the BSD
/// name of the whole-disk `IOMedia` beneath it, and one with no media is left out. Its
/// model and serial number are never read.
extension DarwinSystemSource {

    public func diskSnapshot() throws -> DiskSnapshot {
        let taken = uptimeNanoseconds()
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
        guard status == KERN_SUCCESS else {
            throw SystemSourceError.callFailed(function: "IOServiceGetMatchingServices", code: status)
        }
        defer { IOObjectRelease(iterator) }

        var devices: [DiskDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
                let statistics = IORegistryEntryCreateCFProperty(
                    service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                // A driver with no media beneath it (an empty card reader) has nothing
                // to report.
                let name = Self.bsdName(beneath: service),
                let device = Self.diskDevice(id: entryID, name: name, statistics: statistics)
            else { continue }
            devices.append(device)
        }
        return DiskSnapshot(takenAtNanoseconds: taken, devices: devices)
    }

    /// The BSD name ("disk0") of the whole-disk media a driver exposes; `nil` when it
    /// exposes none.
    private static func bsdName(beneath driver: io_registry_entry_t) -> String? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if let name = IORegistryEntryCreateCFProperty(
                child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            {
                return name
            }
        }
        return nil
    }

    /// Pure over the `Statistics` dictionary, so the tests feed it invented values. Key
    /// strings are the SDK's `kIOBlockStorageDriverStatistics*Key` macros, which Swift does
    /// not import: bytes and operations are counts, the times are nanoseconds.
    static func diskDevice(id: UInt64, name: String, statistics: [String: Any]) -> DiskDevice? {
        func counter(_ key: String) -> UInt64? { (statistics[key] as? NSNumber)?.uint64Value }
        // The byte counters are what make a driver worth listing; without them there is
        // nothing to report, and a zero would read as an idle disk.
        guard let read = counter("Bytes (Read)"), let written = counter("Bytes (Write)") else {
            return nil
        }
        return DiskDevice(
            id: id, name: name, readBytes: read, writtenBytes: written,
            readOperations: counter("Operations (Read)") ?? 0,
            writtenOperations: counter("Operations (Write)") ?? 0,
            readTimeNanoseconds: counter("Total Time (Read)") ?? 0,
            writeTimeNanoseconds: counter("Total Time (Write)") ?? 0)
    }
}
