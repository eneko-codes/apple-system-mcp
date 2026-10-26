import Darwin
import Foundation

extension DarwinSystemSource {

    private static let host = mach_host_self()

    // MARK: CPU

    public func coreTicks() throws -> [CoreTicks] {
        var coreCount: natural_t = 0
        var information: processor_info_array_t?
        var informationCount: mach_msg_type_number_t = 0
        let status = host_processor_info(
            Self.host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &information, &informationCount)
        guard status == KERN_SUCCESS, let information else {
            throw SystemSourceError.callFailed(function: "host_processor_info", code: status)
        }
        // The kernel allocates this array in the caller's address space.
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: information),
                vm_size_t(informationCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let statesPerCore = Int(CPU_STATE_MAX)
        guard Int(informationCount) >= Int(coreCount) * statesPerCore else {
            throw SystemSourceError.unexpectedShape(function: "host_processor_info")
        }
        return (0..<Int(coreCount)).map { core in
            func ticks(_ state: Int32) -> UInt64 {
                UInt64(UInt32(bitPattern: information[core * statesPerCore + Int(state)]))
            }
            return CoreTicks(
                user: ticks(CPU_STATE_USER), system: ticks(CPU_STATE_SYSTEM),
                idle: ticks(CPU_STATE_IDLE), nice: ticks(CPU_STATE_NICE))
        }
    }

    public func loadAverage() throws -> LoadAverage {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else {
            throw SystemSourceError.callFailed(function: "getloadavg", code: errno)
        }
        return LoadAverage(
            oneMinute: averages[0], fiveMinutes: averages[1], fifteenMinutes: averages[2])
    }

    // MARK: Memory

    public func memory() throws -> MemorySnapshot {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Self.host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw SystemSourceError.callFailed(function: "host_statistics64", code: status)
        }

        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(Self.host, &pageSize)
        guard pageStatus == KERN_SUCCESS, pageSize > 0 else {
            throw SystemSourceError.callFailed(function: "host_page_size", code: pageStatus)
        }

        return MemorySnapshot(
            pageSize: UInt64(pageSize), totalBytes: try SystemCalls.sysctlInteger("hw.memsize"),
            freePages: UInt64(statistics.free_count), activePages: UInt64(statistics.active_count),
            inactivePages: UInt64(statistics.inactive_count),
            wiredPages: UInt64(statistics.wire_count),
            compressedPages: UInt64(statistics.compressor_page_count),
            purgeablePages: UInt64(statistics.purgeable_count),
            speculativePages: UInt64(statistics.speculative_count),
            fileBackedPages: UInt64(statistics.external_page_count),
            anonymousPages: UInt64(statistics.internal_page_count),
            swapIns: statistics.swapins, swapOuts: statistics.swapouts)
    }

    public func memoryPressure() throws -> MemoryPressure {
        let level: Int32 = try SystemCalls.sysctlInteger("kern.memorystatus_vm_pressure_level")
        return MemoryPressure(rawValue: level)
    }

    public func swap() throws -> SwapUsage {
        let usage = try SystemCalls.sysctlStructure("vm.swapusage", initial: xsw_usage())
        return SwapUsage(
            totalBytes: usage.xsu_total, usedBytes: usage.xsu_used,
            isEncrypted: usage.xsu_encrypted != 0)
    }

    // MARK: Hardware and kernel

    public func hardware() throws -> HardwareInfo {
        let logical: Int32 = try SystemCalls.sysctlInteger("hw.logicalcpu")
        let physical: Int32 = try SystemCalls.sysctlInteger("hw.physicalcpu")
        let memory: UInt64 = try SystemCalls.sysctlInteger("hw.memsize")

        // Absent on a machine whose cores are all alike.
        var groups: [CoreGroup] = []
        if let levels: Int32 = try? SystemCalls.sysctlInteger("hw.nperflevels"), levels > 1 {
            for level in 0..<levels {
                guard let name = try? SystemCalls.sysctlString("hw.perflevel\(level).name"),
                    let count: Int32 = try? SystemCalls.sysctlInteger(
                        "hw.perflevel\(level).logicalcpu")
                else { continue }
                groups.append(CoreGroup(name: name, count: Int(count)))
            }
        }
        return HardwareInfo(
            chip: try? SystemCalls.sysctlString("machdep.cpu.brand_string"),
            logicalCores: Int(logical), physicalCores: Int(physical), coreGroups: groups,
            memoryBytes: memory)
    }

    public func kernel() throws -> KernelInfo {
        let boot = try SystemCalls.sysctlStructure("kern.boottime", initial: timeval())
        return KernelInfo(
            osVersion: try SystemCalls.sysctlString("kern.osproductversion"),
            build: try SystemCalls.sysctlString("kern.osversion"),
            bootTime: Date(
                timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000))
    }

    // MARK: Network

    public func networkSnapshot() throws -> NetworkSnapshot {
        let taken = uptimeNanoseconds()
        let addresses = interfaceAddresses()

        // The routing sysctl carries 64-bit counters. The 32-bit `if_data` hung off
        // getifaddrs wraps at 4 GiB, which a busy interface passes in minutes.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            throw SystemSourceError.callFailed(function: "sysctl(NET_RT_IFLIST2)", code: errno)
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
            throw SystemSourceError.callFailed(function: "sysctl(NET_RT_IFLIST2)", code: errno)
        }

        var interfaces: [NetworkInterface] = []
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self) }
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0, offset + messageLength <= length else { break }
            defer { offset += messageLength }

            guard Int32(header.ifm_type) == RTM_IFINFO2,
                messageLength >= MemoryLayout<if_msghdr2>.size
            else { continue }
            let message = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            }

            var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { continue }
            let name = SystemCalls.string(fromCChars: nameBuffer)
            let data = message.ifm_data
            interfaces.append(
                NetworkInterface(
                    name: name, isUp: message.ifm_flags & Int32(IFF_UP) != 0,
                    isLoopback: message.ifm_flags & Int32(IFF_LOOPBACK) != 0,
                    addresses: addresses[name] ?? [], receivedBytes: data.ifi_ibytes,
                    sentBytes: data.ifi_obytes, receivedPackets: data.ifi_ipackets,
                    sentPackets: data.ifi_opackets, receiveErrors: data.ifi_ierrors,
                    sendErrors: data.ifi_oerrors))
        }
        return NetworkSnapshot(takenAtNanoseconds: taken, interfaces: interfaces)
    }

    private func interfaceAddresses() -> [String: [String]] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }

        var byName: [String: [String]] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET)
                    || address.pointee.sa_family == UInt8(AF_INET6)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil,
                    0, NI_NUMERICHOST) == 0
            else { continue }
            byName[String(cString: entry.pointee.ifa_name), default: []].append(
                SystemCalls.string(fromCChars: host))
        }
        return byName
    }

    // MARK: Volumes

    public func volumes() throws -> [Volume] {
        // MNT_NOWAIT answers from the kernel's cache. MNT_WAIT asks each file system, and
        // a network volume that has stopped answering would hang the call.
        let counted = getfsstat(nil, 0, MNT_NOWAIT)
        guard counted > 0 else {
            throw SystemSourceError.callFailed(function: "getfsstat", code: errno)
        }
        // `[statfs](...)` would read as an array literal of the statfs function.
        var entries = Array<statfs>(repeating: statfs(), count: Int(counted) + 8)
        let filled = getfsstat(
            &entries, Int32(entries.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard filled > 0 else {
            throw SystemSourceError.callFailed(function: "getfsstat", code: errno)
        }

        return entries.prefix(Int(filled)).map { entry in
            let blockSize = UInt64(entry.f_bsize)
            return Volume(
                mountPoint: SystemCalls.string(fromCArray: entry.f_mntonname),
                device: SystemCalls.string(fromCArray: entry.f_mntfromname),
                fileSystem: SystemCalls.string(fromCArray: entry.f_fstypename),
                totalBytes: UInt64(entry.f_blocks) * blockSize,
                freeBytes: UInt64(entry.f_bfree) * blockSize,
                availableBytes: UInt64(entry.f_bavail) * blockSize,
                isReadOnly: entry.f_flags & UInt32(MNT_RDONLY) != 0,
                isLocal: entry.f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }
}
