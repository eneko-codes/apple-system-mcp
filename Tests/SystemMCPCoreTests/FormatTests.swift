import Foundation
import Testing

@testable import SystemMCPCore

@Suite("Format")
struct FormatTests {

    @Test("Bytes use binary units with one decimal below ten")
    func bytes() {
        #expect(Format.bytes(0) == "0 B")
        #expect(Format.bytes(1023) == "1023 B")
        #expect(Format.bytes(1024) == "1.0 KB")
        #expect(Format.bytes(1536) == "1.5 KB")
        #expect(Format.bytes(10 << 20) == "10 MB")
        #expect(Format.bytes(16 << 30) == "16 GB")
        #expect(Format.bytes(3 << 40) == "3.0 TB")
        // Past the largest unit the number grows instead of the unit running out.
        #expect(Format.bytes(2048 << 40) == "2048 TB")
    }

    @Test("A missing rate reads n/a and a rate reads with a per-second suffix")
    func rates() {
        #expect(Format.bytesPerSecond(nil) == "n/a")
        #expect(Format.bytesPerSecond(2048) == "2.0 KB/s")
        #expect(Format.bytesPerSecond(-5) == "0 B/s")
    }

    @Test("Durations keep the two largest units that apply")
    func durations() {
        #expect(Format.duration(seconds: 0) == "0s")
        #expect(Format.duration(seconds: 59) == "59s")
        #expect(Format.duration(seconds: 61) == "1m 1s")
        #expect(Format.duration(seconds: 3600 + 21 * 60) == "1h 21m")
        #expect(Format.duration(seconds: 17 * 86_400 + 5 * 3600 + 12) == "17d 5h")
        #expect(Format.duration(seconds: -10) == "0s")
    }

    @Test("Percentages have one decimal, and a missing one reads n/a")
    func percentages() {
        #expect(Format.percent(7.55) == "7.5%" || Format.percent(7.55) == "7.6%")
        #expect(Format.percent(100) == "100.0%")
        #expect(Format.percent(nil) == "n/a")
    }

    @Test("A name containing a newline cannot break the one-row-per-process layout")
    func newlinesAreCollapsed() {
        #expect(Format.oneLine("evil\nname\n  with lines") == "evil name with lines")
        let row = Format.ProcessRow(
            record: Sample.record(pid: 7, name: "bad\nname", usage: Sample.usage(cpuSeconds: 1)),
            userName: "us\ner", cpuPercent: 1)
        let text = Format().processList(
            rows: [row], totalVisible: 1, totalReadable: 1, matching: 1, sortedBy: "cpu",
            sampleMilliseconds: 500)
        let dataRows = text.split(separator: "\n").filter { $0.contains("bad name") }
        #expect(dataRows.count == 1)
    }

    @Test("When every process is readable the header does not claim anything is hidden")
    func noHiddenClaimWhenAllReadable() {
        let text = Format().processList(
            rows: [], totalVisible: 4, totalReadable: 4, matching: 0, sortedBy: "cpu",
            sampleMilliseconds: 500)
        #expect(!text.contains("The other"))
        #expect(text.contains("no process matches"))
    }

    @Test("Padding never truncates")
    func padding() {
        #expect(Format.pad("abc", to: 2) == "abc")
        #expect(Format.padLeft("abc", to: 2) == "abc")
        #expect(Format.padLeft("7", to: 3) == "  7")
    }
}
