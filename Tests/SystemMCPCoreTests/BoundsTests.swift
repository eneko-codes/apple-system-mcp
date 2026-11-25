import Foundation
import Testing

@testable import SystemMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every process, address, volume and argument in here is invented.
@Suite("Bounds")
struct BoundsTests {

    // MARK: An invented machine with as many rows as a test asks for

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    /// A process name 48 characters long, about the longest an ordinary one gets (a
    /// reverse-DNS service name). A name is the last component of the executable's path,
    /// so it can be longer still: `widePageShrinks` covers the rows that are.
    private static func longName(_ role: String, _ index: Int) -> String {
        let name = "com.example.invented.\(role).\(padded(index))."
        return name + String(repeating: "x", count: 48 - name.count)
    }

    /// One listing tool, and a machine that gives it `count` rows of the widest ordinary
    /// width, in the order the tool lists them. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var arguments: [String: Value] = [:]
        var source: @Sendable (Int) -> FakeSystemSource
        var row: @Sendable (Int) -> String

        var testDescription: String { tool }

        func call(_ count: Int, _ extra: [String: Value] = [:]) async -> ToolResult {
            await SystemMCPCoreTests.call(
                tool, arguments.merging(extra) { _, new in new }, source: source(count))
        }

        /// The rows of a machine with `count` of them that `text` shows, in order.
        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }
    }

    private static let processes = Listing(
        tool: ToolCatalog.processesName, things: "processes", limits: ToolCatalog.processLimitRange,
        defaultLimit: ToolCatalog.defaultProcessLimit,
        // By pid, because every row of this machine uses the same CPU.
        arguments: ["sort_by": "pid"],
        source: { count in
            let records = (0..<count).map {
                Sample.record(
                    pid: Int32($0 + 1), name: longName("process", $0), usage: Sample.usage(cpuSeconds: 1))
            }
            return FakeSystemSource {
                $0.processSnapshots = [
                    Sample.snapshot(at: 0, records), Sample.snapshot(at: 500_000_000, records),
                ]
            }
        },
        row: { longName("process", $0) })

    private static let connections = Listing(
        tool: ToolCatalog.connectionsName, things: "sockets",
        limits: ToolCatalog.connectionLimitRange, defaultLimit: ToolCatalog.defaultConnectionLimit,
        source: { count in
            FakeSystemSource {
                $0.processSnapshots = [
                    Sample.snapshot(at: 0, [
                        Sample.record(
                            pid: 10, name: longName("listener", 0), usage: Sample.usage(cpuSeconds: 1))
                    ])
                ]
                // A full IPv6 address from the documentation range: the widest a row gets.
                $0.sockets = (0..<count).map {
                    SocketRecord(
                        pid: 10, transport: .tcp, localAddress: "2001:db8:85a3:8d3:1319:8a2e:370:7348",
                        localPort: 10_000 + $0, remoteAddress: "::", remotePort: 0, state: "LISTEN")
                }
            }
        },
        row: { "7348:\(10_000 + $0) " })

    private static let network = Listing(
        tool: ToolCatalog.networkName, things: "interfaces", limits: ToolCatalog.interfaceLimitRange,
        defaultLimit: ToolCatalog.defaultInterfaceLimit,
        source: { count in
            let interfaces = (0..<count).map {
                NetworkInterface(
                    name: "en\($0)", isUp: true, isLoopback: false,
                    addresses: [
                        "192.0.2.\($0 % 250)", "2001:db8:85a3:8d3:1319:8a2e:370:7348",
                        "fe80::1c5a:b3ff:fe21:9d04%en\($0)",
                    ],
                    receivedBytes: 123_456_789_012, sentBytes: 98_765_432_109,
                    receivedPackets: 1_234_567_890, sentPackets: 987_654_321)
            }
            return FakeSystemSource {
                $0.networkSnapshots = [
                    NetworkSnapshot(takenAtNanoseconds: 0, interfaces: interfaces),
                    NetworkSnapshot(takenAtNanoseconds: 1_000_000_000, interfaces: interfaces),
                ]
            }
        },
        row: { "  en\($0) — up" })

    private static let volumes = Listing(
        tool: ToolCatalog.volumesName, things: "volumes", limits: ToolCatalog.volumeLimitRange,
        defaultLimit: ToolCatalog.defaultVolumeLimit,
        source: { count in
            FakeSystemSource {
                $0.volumes = (0..<count).map {
                    Sample.volume("/Library/Developer/CoreSimulator/Volumes/Invented_Runtime_\(padded($0))")
                }
            }
        },
        row: { "Invented_Runtime_\(padded($0))" })

    private static let disks = Listing(
        tool: ToolCatalog.disksName, things: "storage drivers", limits: ToolCatalog.diskLimitRange,
        defaultLimit: ToolCatalog.defaultDiskLimit,
        source: { count in
            let devices = (0..<count).map {
                DiskDevice(
                    id: UInt64($0), name: "disk\($0)", readBytes: 123_456_789_012,
                    writtenBytes: 98_765_432_109, readOperations: 1_234_567_890,
                    writtenOperations: 987_654_321, readTimeNanoseconds: 5_000_000_000,
                    writeTimeNanoseconds: 7_000_000_000)
            }
            return FakeSystemSource {
                $0.diskSnapshots = [
                    DiskSnapshot(takenAtNanoseconds: 0, devices: devices),
                    DiskSnapshot(takenAtNanoseconds: 1_000_000_000, devices: devices),
                ]
            }
        },
        row: { "  disk\($0)\n" })

    private static func parent(children count: Int, arguments: [String] = []) -> FakeSystemSource {
        FakeSystemSource {
            $0.details[10] = [
                ProcessDetail(
                    record: Sample.record(pid: 10, name: "alpha", usage: Sample.usage(cpuSeconds: 1)),
                    // Out of order, as the system hands them over.
                    childPIDs: (0..<count).reversed().map { Int32(100 + $0) })
            ]
            for index in 0..<count {
                $0.details[Int32(100 + index)] = [
                    ProcessDetail(
                        record: Sample.record(
                            pid: Int32(100 + index), name: longName("child", index), parent: 10, usage: nil))
                ]
            }
            $0.argumentsByPID[10] = arguments
        }
    }

    private static let children = Listing(
        tool: ToolCatalog.processName, things: "children", limits: ToolCatalog.childLimitRange,
        defaultLimit: ToolCatalog.defaultChildLimit, arguments: ["pid": 10],
        source: { parent(children: $0) },
        row: { "(\(longName("child", $0)))" })

    private static let listings = [processes, connections, network, volumes, disks, children]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                """
                limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.
                Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.


                """))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 \(listing.things). Pass offset=3 for the next page.\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 \(listing.things). Pass offset=6 for the next page.\n\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)

        let lastRow = await listing.call(7, ["offset": .int(6)])
        #expect(listing.rows(in: lastRow.text, of: 7) == [6])

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = ToolCatalog.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("An empty page says whether nothing matched or the offset skipped everything")
    func emptyPages() async {
        for listing in [Self.processes, Self.connections, Self.network, Self.volumes, Self.disks] {
            let past = await listing.call(3, ["offset": .int(9)])
            #expect(past.text.contains("(nothing at this offset)"), "\(listing.tool)")
            let none = await listing.call(0)
            #expect(!none.text.contains("(nothing at this offset)"), "\(listing.tool)")
            #expect(!none.text.contains("Showing"), "\(listing.tool)")
        }
    }

    @Test("A listing states its order")
    func orderIsStated() async {
        #expect(await Self.processes.call(1).text.contains("ordered by pid"))
        #expect(await Self.processes.call(1, ["sort_by": "cpu"]).text.contains("ordered by CPU % (highest first"))
        #expect(await Self.connections.call(1).text.contains("ordered by local port, then pid"))
        #expect(await Self.network.call(1).text.contains("ordered by name"))
        #expect(await Self.volumes.call(1).text.contains("ordered by mount point"))
        #expect(await Self.disks.call(1).text.contains("ordered by name"))
    }

    @Test("Names are ordered so that en2 comes before en10, the same on every call")
    func namesOrderNumerically() async {
        let result = await Self.network.call(12)
        let positions = [2, 10].compactMap { result.text.range(of: Self.network.row($0))?.lowerBound }
        #expect(positions.count == 2 && positions[0] < positions[1])
    }

    // MARK: Rows wider than any maximum foresaw

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // The number leads the name, so that looking for a row never has to walk the filler.
        let wide = String(repeating: "w", count: 1000)
        let records = (0..<200).map {
            Sample.record(pid: Int32($0 + 1), name: "row-\(Self.padded($0))-\(wide)", usage: Sample.usage(cpuSeconds: 1))
        }
        func source() -> FakeSystemSource {
            FakeSystemSource {
                $0.processSnapshots = [Sample.snapshot(at: 0, records), Sample.snapshot(at: 1, records)]
            }
        }
        var offset = 0
        var seen: [Int] = []
        while offset < records.count {
            let result = await call(
                ToolCatalog.processesName,
                ["sort_by": "pid", "limit": .int(200), "offset": .int(offset)], source: source())
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<records.count).filter { result.text.contains("row-\(Self.padded($0))-") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < 200)
            let next = last + 1 < records.count ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) of 200 processes. \(next)\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<records.count))
    }

    @Test("fitting halves the size only while the text is too long, and stops at one")
    func fitting() {
        var asked: [Int] = []
        let fits = ToolStandard.fitting(8) { size in
            asked.append(size)
            return "short"
        }
        #expect(fits == "short" && asked == [8])

        asked = []
        let shrunk = ToolStandard.fitting(8) { size in
            asked.append(size)
            return String(repeating: "x", count: size * ToolStandard.longestResult / 2)
        }
        #expect(asked == [8, 4, 2])
        #expect(shrunk.utf16.count == ToolStandard.longestResult)

        asked = []
        _ = ToolStandard.fitting(4) { size in
            asked.append(size)
            return String(repeating: "x", count: ToolStandard.longestResult + 1)
        }
        #expect(asked == [4, 2, 1])
    }

    // MARK: The window on a process's arguments

    private static let manyArguments =
        ["/Applications/alpha"] + (0..<800).map { "--invented-option-\(padded($0))=value-\(padded($0))" }

    private static let argumentHeading = "the environment is never read):\n"

    private func argumentWindow(_ text: String) throws -> String {
        let heading = try #require(text.range(of: Self.argumentHeading))
        return String(text[heading.upperBound...])
    }

    private func arguments(_ extra: [String: Value] = [:], of list: [String] = manyArguments) async -> ToolResult {
        await call(
            ToolCatalog.processName,
            ["pid": 10, "include_arguments": true].merging(extra) { _, new in new },
            source: Self.parent(children: 0, arguments: list))
    }

    @Test("A long argument listing comes as one default window, announced before the data")
    func defaultWindow() async throws {
        let whole = Format.argumentListing(Self.manyArguments)
        let size = ToolCatalog.defaultMaxCharacters
        #expect(whole.count > size)
        let result = await arguments()
        #expect(result.text.hasPrefix("Arguments: characters 1–\(size) of \(whole.count). Pass character_offset=\(size) for the rest.\n\nProcess 10"))
        #expect(try argumentWindow(result.text) == String(whole.prefix(size)))
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole listing")
    func windowsChain() async throws {
        let whole = Format.argumentListing(Self.manyArguments)
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await arguments(["character_offset": .int(offset), "max_characters": .int(7000)])
            let window = try argumentWindow(result.text)
            let last = offset + window.count
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            if offset == 0 && last == whole.count {
                #expect(!result.text.contains("Arguments: characters"))
            } else {
                #expect(result.text.hasPrefix("Arguments: characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            }
            #expect(window.count == min(7000, whole.count - offset))
            joined += window
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("A listing that fits one window carries no notice")
    func shortListingHasNoNotice() async throws {
        let result = await arguments(of: ["/Applications/alpha", "--verbose"])
        #expect(!result.text.contains("Arguments: characters"))
        #expect(try argumentWindow(result.text) == "  [0] /Applications/alpha\n  [1] --verbose")
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func windowSizeBounds() async throws {
        let whole = Format.argumentListing(Self.manyArguments)
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        #expect(whole.count > maximum)

        let atMaximum = await arguments(["max_characters": .int(maximum)])
        #expect(!atMaximum.text.contains("is outside"))
        #expect(try argumentWindow(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await arguments(["max_characters": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nArguments: characters 1–\(maximum) of "))
        #expect(try argumentWindow(over.text).count == maximum)

        let under = await arguments(["max_characters": .int(0)])
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\nArguments: characters 1–1 of "))
        #expect(try argumentWindow(under.text) == " ")
    }

    @Test("character_offset past the end returns no text and says so; a negative one is moved to zero")
    func windowOffsetEdges() async throws {
        let whole = Format.argumentListing(Self.manyArguments)
        let past = await arguments(["character_offset": .int(whole.count + 50)])
        #expect(
            past.text.hasPrefix(
                "Arguments: characters 0 of \(whole.count): character_offset=\(whole.count + 50) is past the end. That is all.\n\n"))
        #expect(try argumentWindow(past.text).isEmpty)

        let negative = await arguments(["character_offset": .int(-3)])
        let range = ToolCatalog.offsetRange
        #expect(
            negative.text.hasPrefix(
                "character_offset=-3 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\nArguments: characters 1–"))
    }

    @Test("A window of characters that take several UTF-16 units each still fits a result, and still chains")
    func windowOfWideCharacters() async throws {
        // Eight UTF-16 units to the character: a full window would be four results long.
        let list = (0..<300).map { _ in String(repeating: "👩‍👩‍👧", count: 100) }
        let whole = Format.argumentListing(list)
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await arguments(
                ["character_offset": .int(offset), "max_characters": .int(maximum)], of: list)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let window = try argumentWindow(result.text)
            #expect(!window.isEmpty && window.count < maximum)
            let last = offset + window.count
            #expect(result.text.contains("Arguments: characters \(offset + 1)–\(last) of \(whole.count). "))
            joined += window
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("The window is cut from the masked listing, so no window can hold what the mask removed")
    func windowIsOfMaskedText() async throws {
        let list = ["/Applications/alpha", "--token", "invented-secret-value", "--verbose"]
        var joined = ""
        for offset in stride(from: 0, to: 200, by: 5) {
            let result = await arguments(
                ["character_offset": .int(offset), "max_characters": .int(5)], of: list)
            joined += try argumentWindow(result.text)
        }
        #expect(!joined.contains("invented-secret-value"))
        #expect(joined == Format.argumentListing(ProcessArguments.redact(list)))
    }

    @Test("A process's children and its arguments are each announced, both before the data")
    func childrenAndArgumentsTogether() async {
        let result = await call(
            ToolCatalog.processName, ["pid": 10, "include_arguments": true, "limit": .int(2)],
            source: Self.parent(children: 5, arguments: Self.manyArguments))
        let whole = Format.argumentListing(Self.manyArguments).count
        let size = ToolCatalog.defaultMaxCharacters
        #expect(
            result.text.hasPrefix(
                """
                Showing 1–2 of 5 children. Pass offset=2 for the next page.
                Arguments: characters 1–\(size) of \(whole). Pass character_offset=\(size) for the rest.

                Process 10 — alpha
                """))
        #expect(!result.text.contains("more"))
    }

    // MARK: Numbers moved, values refused

    @Test("sample_ms outside its range is moved, and the result says which value was used")
    func sampleIsReported() async {
        let ticks = [CoreTicks(user: 1, system: 1, idle: 1, nice: 0)]
        let overview = await call(
            ToolCatalog.overviewName, ["sample_ms": .int(99_999)],
            source: FakeSystemSource { $0.coreTicks = [ticks, ticks] })
        let range = ToolCatalog.sampleRange
        #expect(
            overview.text.hasPrefix(
                "sample_ms=99999 is outside \(range.lowerBound)–\(range.upperBound); \(range.upperBound) was used.\n\nmacOS"))

        for listing in [Self.processes, Self.network, Self.disks, Self.children] {
            let sleeps = SleepRecorder()
            let result = await call(
                listing.tool, listing.arguments.merging(["sample_ms": .int(-5)]) { _, new in new },
                source: listing.source(1), sleeps: sleeps)
            #expect(result.text.hasPrefix("sample_ms=-5 is outside "), "\(listing.tool)")
            #expect(result.text.contains(" was used.\n\n"), "\(listing.tool)")
            #expect(sleeps.milliseconds.allSatisfy { $0 >= 0 }, "\(listing.tool)")
        }

        let inside = await call(
            ToolCatalog.overviewName, ["sample_ms": .int(range.upperBound)],
            source: FakeSystemSource { $0.coreTicks = [ticks, ticks] })
        #expect(inside.text.hasPrefix("macOS"))
    }

    @Test("A wrong type is refused with the form expected")
    func wrongTypesAreRefused() async {
        let cases: [(tool: String, arguments: [String: Value], expected: String)] = [
            (ToolCatalog.processesName, ["limit": "ten"], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.processesName, ["limit": 2.5], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.processesName, ["offset": true], "Argument 'offset' is not valid: a whole number was expected"),
            (ToolCatalog.processesName, ["name_contains": 5], "Argument 'name_contains' is not valid: text was expected"),
            (ToolCatalog.processesName, ["user": ["root"]], "Argument 'user' is not valid: text was expected"),
            (ToolCatalog.processesName, ["sort_by": 3], "expected one of: cpu, memory, name, pid"),
            (ToolCatalog.processName, ["pid": "10"], "Argument 'pid' is not valid: a whole number was expected"),
            (ToolCatalog.processName, ["pid": 10, "include_arguments": "yes"], "true or false was expected"),
            (ToolCatalog.processName, ["pid": 10, "max_characters": "all"], "Argument 'max_characters' is not valid"),
            (ToolCatalog.volumesName, ["limit": [1]], "Argument 'limit' is not valid"),
        ]
        for (tool, arguments, expected) in cases {
            let result = await call(tool, arguments, source: Self.parent(children: 0))
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments): \(result.text)")
        }
    }

    @Test("A whole number sent as 20.0 is taken as 20, and a null as not given")
    func lenientForms() async {
        let result = await Self.processes.call(30, ["limit": 20.0, "offset": .null, "name_contains": .null])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–20 of 30 processes."))
    }

    @Test("A pid or a port outside its range is refused, never moved to another one")
    func identifiersAreRefused() async {
        let pids = ToolCatalog.pidRange
        let expectedPID = "a whole number from \(pids.lowerBound) to \(pids.upperBound) was expected"
        // 4294967306 is 10 once truncated to 32 bits: it must not inspect process 10.
        for pid in [-1, pids.upperBound + 1, 4_294_967_306] {
            let result = await call(ToolCatalog.processName, ["pid": .int(pid)], source: Self.parent(children: 0))
            #expect(result.isError && result.text.contains("Argument 'pid' is not valid: \(expectedPID)"), "\(pid)")
        }
        let parent = await call(ToolCatalog.processesName, ["parent_pid": .int(-1)], source: FakeSystemSource())
        #expect(parent.isError && parent.text.contains("Argument 'parent_pid' is not valid: \(expectedPID)"))
        let owner = await call(ToolCatalog.connectionsName, ["pid": .int(pids.upperBound + 1)], source: FakeSystemSource())
        #expect(owner.isError && owner.text.contains("Argument 'pid' is not valid"))

        let ports = ToolCatalog.portRange
        for port in [ports.lowerBound - 1, ports.upperBound + 1] {
            let result = await call(ToolCatalog.connectionsName, ["port": .int(port)], source: FakeSystemSource())
            #expect(result.isError, "\(port)")
            #expect(
                result.text.contains("a whole number from \(ports.lowerBound) to \(ports.upperBound) was expected"),
                "\(port)")
        }
        for port in [ports.lowerBound, ports.upperBound] {
            let result = await call(ToolCatalog.connectionsName, ["port": .int(port)], source: FakeSystemSource())
            #expect(!result.isError, "\(port)")
        }
        let edge = await call(ToolCatalog.processName, ["pid": .int(pids.upperBound)], source: FakeSystemSource())
        #expect(edge.text.contains("No process with pid \(pids.upperBound)"))
    }

    // MARK: Errors and time

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async {
        let name = String(repeating: "n", count: 5000)
        let result = await call(name, source: FakeSystemSource())
        #expect(result.isError)
        #expect(result.text.contains("is not a tool of this server"))
        #expect(result.text.contains(String(repeating: "n", count: ToolStandard.echoWidth) + "…"))
        #expect(result.text.count < ToolStandard.echoWidth + 60)
        #expect(ToolStandard.echo("system_reboot") == "system_reboot")
    }

    @Test("Every error this server words is far inside the longest error")
    func errorsAreShort() {
        let errors: [ToolError] = [
            .missingArgument("pid"), .badArgument(name: "limit", reason: "a whole number was expected"),
            .unknownTool(String(repeating: "n", count: 5000)), .processNotFound(pid: 10),
            .systemFailure(function: "proc_pidinfo", code: 3), .timedOut(seconds: 30),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError / 10, "\(Diagnostics.kind(of: error))")
        }
    }

    @Test("The deadline of a call, and the longest sample inside it, are within the standard's time limit")
    func deadlineIsWithinTheTimeLimit() {
        #expect(SystemTools.defaultTimeout <= ToolStandard.timeLimit)
        for range in [ToolCatalog.sampleRange, ToolCatalog.networkSampleRange, ToolCatalog.diskSampleRange] {
            #expect(Duration.milliseconds(range.upperBound) < SystemTools.defaultTimeout)
        }
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(ToolStandard.overlongTexts(instructions: SystemMCPServer.instructions, catalog: ToolCatalog.all()).isEmpty)
        #expect(!SystemMCPServer.instructions.isEmpty)
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("Every listing's schema states the range and default of limit and offset that the code enforces", arguments: listings)
    private func schemaStatesThePage(_ listing: Listing) throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == listing.tool })
        let limit = try #require(properties(of: tool)["limit"])
        #expect(limit["minimum"]?.intValue == listing.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == listing.limits.upperBound)
        #expect(limit["default"]?.intValue == listing.defaultLimit)
        let offset = try #require(properties(of: tool)["offset"])
        #expect(offset["minimum"]?.intValue == ToolCatalog.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == ToolCatalog.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)
        // The description states the same maximum, taken from the same constant.
        #expect(tool.description?.contains("limit (up to \(listing.limits.upperBound))") == true)
        #expect(tool.description?.contains("\(listing.defaultLimit)") == true)
    }

    @Test("The instructions state the samples the code uses, and their longest")
    func instructionsStateTheSamples() {
        let instructions = SystemMCPServer.instructions
        #expect(instructions.contains("\(ToolCatalog.defaultSampleMilliseconds) ms for CPU"))
        #expect(instructions.contains("\(ToolCatalog.defaultNetworkSampleMilliseconds) ms for network rates"))
        #expect(instructions.contains("\(ToolCatalog.defaultDiskSampleMilliseconds) ms for disk rates"))
        #expect(instructions.contains("at most \(ToolCatalog.longestSampleMilliseconds) ms"))
        for range in [ToolCatalog.sampleRange, ToolCatalog.networkSampleRange, ToolCatalog.diskSampleRange] {
            #expect(range.upperBound == ToolCatalog.longestSampleMilliseconds)
        }
        #expect(instructions.contains("after \(SystemTools.defaultTimeout.components.seconds) seconds"))
    }

    @Test("The window's schema states the range and default the code enforces")
    func schemaStatesTheWindow() throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.processName })
        let size = try #require(properties(of: tool)["max_characters"])
        #expect(size["minimum"]?.intValue == ToolCatalog.maxCharactersRange.lowerBound)
        #expect(size["maximum"]?.intValue == ToolCatalog.maxCharactersRange.upperBound)
        #expect(size["default"]?.intValue == ToolCatalog.defaultMaxCharacters)
        #expect(ToolCatalog.defaultMaxCharacters == ToolStandard.usualPage)
        let offset = try #require(properties(of: tool)["character_offset"])
        #expect(offset["minimum"]?.intValue == 0 && offset["default"]?.intValue == 0)
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() {
        for tool in ToolCatalog.all() {
            for (name, property) in properties(of: tool) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue
                else {
                    Issue.record("\(tool.name).\(name) states no range")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page and window a result")
    func standardArgumentNames() {
        let standard: Set = ["limit", "offset", "character_offset", "max_characters"]
        let lookalikes: Set = [
            "max", "count", "max_results", "page", "page_size", "skip", "start", "from", "to",
            "max_chars", "max_length", "char_offset", "cursor",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(properties(of: tool).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
    }
}
