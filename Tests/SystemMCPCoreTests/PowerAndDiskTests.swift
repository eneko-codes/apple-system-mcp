import Foundation
import Testing

@testable import SystemMCPCore

/// `system_battery` and `system_disks` against an invented machine. Every name, number and
/// state in here is made up; nothing reads the real power sources or storage drivers.
@Suite("Power and disks")
struct PowerAndDiskTests {

    // MARK: Battery

    private func battery(
        state: String = "AC Power", charging: Bool = true, charged: Bool = false,
        current: Int = 87, maximum: Int = 100, toEmpty: Int? = nil, toFull: Int? = 42,
        health: String? = "Good", present: Bool = true
    ) -> PowerSource {
        PowerSource(
            name: "InternalBattery-0", kind: "InternalBattery", state: state, isPresent: present,
            isCharging: charging, isCharged: charged, currentCapacity: current,
            maxCapacity: maximum, timeToEmptyMinutes: toEmpty, timeToFullMinutes: toFull,
            health: health, healthCondition: nil, temperatureCelsius: 31, voltageMillivolts: 12_800,
            currentMilliamps: 1500, hasInternalFailure: false)
    }

    private func powered(_ providing: String?, _ sources: [PowerSource]) -> FakeSystemSource {
        FakeSystemSource { $0.power = PowerStatus(providing: providing, sources: sources) }
    }

    @Test("A charging battery shows its level, state and time to full")
    func chargingBattery() async {
        let result = await call("system_battery", source: powered("AC Power", [battery()]))
        #expect(!result.isError)
        #expect(result.text.contains("87%"))
        #expect(result.text.contains("AC Power"))
        #expect(result.text.contains("charging"))
        #expect(result.text.contains("42m"))
        #expect(result.text.contains("Good"))
    }

    @Test("A battery's details are indented under its name")
    func batteryLayout() async {
        let result = await call("system_battery", source: powered("AC Power", [battery()]))
        #expect(result.text.contains("\n  InternalBattery-0 (InternalBattery)\n      charge"))
    }

    @Test("On battery power the time left is shown, and an unknown time says it is still being worked out")
    func dischargingBattery() async {
        let known = await call(
            "system_battery",
            source: powered("Battery Power", [battery(state: "Battery Power", charging: false, toEmpty: 185, toFull: nil)]))
        #expect(known.text.contains("Battery Power"))
        #expect(known.text.contains("3h 5m"))
        #expect(known.text.contains("discharging"))

        let unknown = await call(
            "system_battery",
            source: powered("Battery Power", [battery(state: "Battery Power", charging: false, toEmpty: -1, toFull: nil)]))
        #expect(unknown.text.contains("still being calculated"))
    }

    @Test("A fully charged battery on mains says so instead of charging")
    func chargedBattery() async {
        let result = await call(
            "system_battery",
            source: powered("AC Power", [battery(charging: false, charged: true, current: 100, toFull: nil)]))
        #expect(result.text.contains("fully charged"))
        #expect(!result.text.contains("still being calculated"))
    }

    @Test("A Mac with no battery or UPS is a plain answer, not an error")
    func noBattery() async {
        let result = await call("system_battery", source: powered(nil, []))
        #expect(!result.isError)
        #expect(result.text.contains("No battery"))
    }

    @Test("An empty battery bay is reported as not present")
    func absentBattery() async {
        let result = await call("system_battery", source: powered("AC Power", [battery(present: false)]))
        #expect(result.text.contains("not present"))
    }

    @Test("A failing power read is reported with its function and code")
    func batteryFailure() async {
        let source = powered("AC Power", [battery()])
        source.state.withLock {
            $0.powerError = SystemSourceError.callFailed(function: "IOPSCopyPowerSourcesInfo", code: 5)
        }
        let result = await call("system_battery", source: source)
        #expect(result.isError)
        #expect(result.text.contains("IOPSCopyPowerSourcesInfo"))
    }

    // MARK: Disks

    private func disk(
        _ id: UInt64 = 1, _ name: String = "disk0", read: UInt64 = 0, written: UInt64 = 0,
        reads: UInt64 = 0, writes: UInt64 = 0, readTime: UInt64 = 0, writeTime: UInt64 = 0
    ) -> DiskDevice {
        DiskDevice(
            id: id, name: name, readBytes: read, writtenBytes: written, readOperations: reads,
            writtenOperations: writes, readTimeNanoseconds: readTime,
            writeTimeNanoseconds: writeTime)
    }

    private func readings(_ first: [DiskDevice], _ second: [DiskDevice], gap: UInt64 = 1_000_000_000)
        -> FakeSystemSource
    {
        FakeSystemSource {
            $0.diskSnapshots = [
                DiskSnapshot(takenAtNanoseconds: 0, devices: first),
                DiskSnapshot(takenAtNanoseconds: gap, devices: second),
            ]
        }
    }

    @Test("Rates are the counter delta over the elapsed time, with average latency per operation")
    func diskRates() async {
        let source = readings(
            [disk(read: 0, written: 0, reads: 0, writes: 0)],
            [disk(read: 4 << 20, written: 2 << 20, reads: 100, writes: 50, readTime: 200_000_000, writeTime: 50_000_000)])
        let sleeps = SleepRecorder()
        let result = await call("system_disks", source: source, sleeps: sleeps)
        #expect(!result.isError)
        #expect(sleeps.milliseconds == [ToolCatalog.defaultDiskSampleMilliseconds])
        #expect(result.text.contains("disk0"))
        #expect(result.text.contains("4.0 MB/s"))
        #expect(result.text.contains("2.0 MB/s"))
        #expect(result.text.contains("100 reads/s"))
        #expect(result.text.contains("50 writes/s"))
        // 200 ms over 100 reads is 2 ms each, 50 ms over 50 writes is 1 ms each.
        #expect(result.text.contains("2.0 ms"))
        #expect(result.text.contains("1.0 ms"))
    }

    @Test("sample_ms 0 returns totals only and waits for nothing")
    func diskTotalsOnly() async {
        let source = readings([disk(read: 10 << 20)], [disk(read: 20 << 20)])
        let sleeps = SleepRecorder()
        let result = await call("system_disks", ["sample_ms": .int(0)], source: source, sleeps: sleeps)
        #expect(sleeps.milliseconds.isEmpty)
        #expect(result.text.contains("10 MB"))
        #expect(!result.text.contains("/s"))
    }

    @Test("A counter that went backwards has no rate")
    func diskCounterReset() async {
        let source = readings([disk(read: 5 << 20)], [disk(read: 1 << 20)])
        let result = await call("system_disks", source: source)
        #expect(result.text.contains("n/a"))
    }

    @Test("A device that appears between the readings is listed without a rate")
    func diskAppearsLate() async {
        let source = readings([], [disk(7, "disk4", read: 1 << 20)])
        let result = await call("system_disks", source: source)
        #expect(result.text.contains("disk4"))
        #expect(result.text.contains("n/a"))
    }

    @Test("Devices are told apart by id, so two with one name keep their own counters")
    func diskSameNameTwice() async {
        let source = readings(
            [disk(1, "disk0"), disk(2, "disk0")],
            [disk(1, "disk0", read: 1 << 20), disk(2, "disk0", read: 3 << 20)])
        let result = await call("system_disks", source: source)
        #expect(result.text.contains("1.0 MB/s"))
        #expect(result.text.contains("3.0 MB/s"))
    }

    @Test("No storage drivers is a plain answer")
    func noDisks() async {
        let result = await call("system_disks", source: readings([], []))
        #expect(!result.isError)
        #expect(result.text.contains("(none)"))
    }

    @Test("Disk sample_ms is clamped to the advertised range")
    func diskSampleClamped() async {
        let sleeps = SleepRecorder()
        _ = await call("system_disks", ["sample_ms": .int(99_999)], source: readings([], []), sleeps: sleeps)
        #expect(sleeps.milliseconds == [ToolCatalog.diskSampleRange.upperBound])
    }

    @Test("Average latency is time over operations, and absent when nothing happened")
    func latencyMath() {
        #expect(Metrics.averageLatencyNanoseconds(timeDelta: 200, operationsDelta: 100) == 2)
        #expect(Metrics.averageLatencyNanoseconds(timeDelta: 0, operationsDelta: 0) == nil)
    }

    // MARK: Decoding what the system returns (invented dictionaries)

    @Test("A power-source dictionary is decoded by the documented keys, and the serial is left out")
    func powerSourceDecoding() throws {
        let description: [String: Any] = [
            "Name": "InternalBattery-0", "Type": "InternalBattery", "Power Source State": "Battery Power",
            "Is Present": true, "Is Charging": false, "Is Charged": false, "Current Capacity": 64,
            "Max Capacity": 100, "Time to Empty": 130, "BatteryHealth": "Good", "Temperature": 29,
            "Voltage": 12_500, "Current": -900, "Hardware Serial Number": "SERIAL-000",
        ]
        let source = try #require(DarwinSystemSource.powerSource(from: description))
        #expect(source.name == "InternalBattery-0")
        #expect(source.state == "Battery Power")
        #expect(source.currentCapacity == 64)
        #expect(source.timeToEmptyMinutes == 130)
        #expect(source.timeToFullMinutes == nil)
        #expect(source.currentMilliamps == -900)
        #expect(source.isPresent && !source.isCharging)
        #expect(!String(describing: source).contains("SERIAL-000"))
    }

    @Test("A dictionary with no name is not a power source")
    func nameless() {
        #expect(DarwinSystemSource.powerSource(from: ["Current Capacity": 50]) == nil)
    }

    @Test("A Statistics dictionary becomes counters; one without byte counts is skipped")
    func diskStatisticsDecoding() throws {
        let statistics: [String: Any] = [
            "Bytes (Read)": NSNumber(value: UInt64(5_000_000_000_000)), "Bytes (Write)": 7_000,
            "Operations (Read)": 11, "Operations (Write)": 13, "Total Time (Read)": 1_000,
            "Total Time (Write)": 2_000,
        ]
        let device = try #require(DarwinSystemSource.diskDevice(id: 9, name: "disk9", statistics: statistics))
        #expect(device.readBytes == 5_000_000_000_000)
        #expect(device.writtenOperations == 13)
        #expect(device.writeTimeNanoseconds == 2_000)
        #expect(DarwinSystemSource.diskDevice(id: 1, name: "disk1", statistics: ["Operations (Read)": 1]) == nil)
    }
}
