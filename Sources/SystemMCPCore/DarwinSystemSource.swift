import Darwin
import Foundation

/// Reads the real machine through the system's own C interfaces: libproc and sysctl for
/// processes, Mach for CPU and memory, getifaddrs and the routing sysctl for the network,
/// getfsstat for volumes. No file contents, no network traffic, no write of any kind.
///
/// Stateless: every call asks the kernel afresh. The type exists so the tools can be
/// handed a double instead.
public struct DarwinSystemSource: SystemSource {

    public init() {}

    public func uptimeNanoseconds() -> UInt64 {
        SystemCalls.nanoseconds(fromMachTicks: mach_continuous_time())
    }

    // MARK: Processes

    public func processSnapshot() throws -> ProcessSnapshot {
        let taken = uptimeNanoseconds()
        var records: [Int32: ProcessRecord] = [:]
        for pid in try processIdentifiers() {
            // A process can exit between the listing and the read. Skipping it is correct:
            // the answer is about the processes that were alive.
            guard let identity = identity(of: pid) else { continue }
            records[pid] = ProcessRecord(identity: identity, usage: usage(of: pid))
        }
        return ProcessSnapshot(takenAtNanoseconds: taken, records: records)
    }

    public func processDetail(pid: Int32) throws -> ProcessDetail? {
        guard let identity = identity(of: pid) else { return nil }
        let record = ProcessRecord(identity: identity, usage: usage(of: pid))

        var startTime: Date?
        var basic = proc_bsdinfo()
        let basicSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &basic, basicSize) == basicSize {
            startTime = Date(
                timeIntervalSince1970: TimeInterval(basic.pbi_start_tvsec)
                    + TimeInterval(basic.pbi_start_tvusec) / 1_000_000)
        }

        var workingDirectory: String?
        var vnode = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize {
            let path = SystemCalls.string(fromCArray: vnode.pvi_cdir.vip_path)
            workingDirectory = path.isEmpty ? nil : path
        }

        let descriptorBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let descriptorCount =
            descriptorBytes > 0 ? Int(descriptorBytes) / MemoryLayout<proc_fdinfo>.stride : nil

        return ProcessDetail(
            record: record, startTime: startTime, workingDirectory: workingDirectory,
            childPIDs: childProcessIdentifiers(of: pid), openDescriptorCount: descriptorCount)
    }

    public func arguments(pid: Int32) throws -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }
        return ProcessArguments.parse(Array(buffer.prefix(length)))
    }

    public func userName(userID: UInt32) -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var scratch = [CChar](repeating: 0, count: 4096)
        guard getpwuid_r(userID, &entry, &scratch, scratch.count, &result) == 0, result != nil,
            let name = entry.pw_name
        else { return nil }
        return String(cString: name)
    }

    // MARK: Process helpers

    private func processIdentifiers() throws -> [Int32] {
        // proc_listallpids answers in pids, not bytes, and the table can grow between the
        // size query and the read, so leave room.
        let counted = proc_listallpids(nil, 0)
        guard counted > 0 else {
            throw SystemSourceError.callFailed(function: "proc_listallpids", code: errno)
        }
        let capacity = Int(counted) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let filled = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard filled > 0 else {
            throw SystemSourceError.callFailed(function: "proc_listallpids", code: errno)
        }
        return Array(pids.prefix(Int(filled))).filter { $0 >= 0 }
    }

    private func childProcessIdentifiers(of pid: Int32) -> [Int32] {
        let counted = proc_listchildpids(pid, nil, 0)
        guard counted > 0 else { return [] }
        let capacity = Int(counted) + 16
        var children = [pid_t](repeating: 0, count: capacity)
        let filled = proc_listchildpids(pid, &children, Int32(capacity * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(children.prefix(Int(filled))).filter { $0 > 0 }
    }

    /// Answers for every process, readable or not: this is the call macOS does not
    /// restrict by owner.
    private func identity(of pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }

        let path = executablePath(of: pid)
        let shortName = SystemCalls.string(fromCArray: info.pbsi_comm)
        let fullName = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return ProcessIdentity(
            pid: pid, parentPID: Int32(truncatingIfNeeded: info.pbsi_ppid), userID: info.pbsi_uid,
            name: fullName.isEmpty ? shortName : fullName, path: path,
            state: Self.state(fromStatus: info.pbsi_status))
    }

    /// The header defines this as `4 * MAXPATHLEN`, a macro Swift does not import.
    private static let maximumPathBytes = 4 * Int(MAXPATHLEN)

    private func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Self.maximumPathBytes)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return SystemCalls.string(fromCChars: buffer)
    }

    /// Only readable for processes of the same user unless the caller is root, so `nil`
    /// is an ordinary answer and not an error.
    private func usage(of pid: Int32) -> ProcessUsage? {
        var counters = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &counters) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return nil }

        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let haveTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize

        // These two are in Mach ticks, not nanoseconds.
        let cpuTicks = counters.ri_user_time &+ counters.ri_system_time
        return ProcessUsage(
            cpuTimeNanoseconds: SystemCalls.nanoseconds(fromMachTicks: cpuTicks),
            footprintBytes: counters.ri_phys_footprint,
            residentBytes: haveTask ? task.pti_resident_size : counters.ri_resident_size,
            threadCount: haveTask ? Int(task.pti_threadnum) : 0,
            diskReadBytes: counters.ri_diskio_bytesread,
            diskWrittenBytes: counters.ri_diskio_byteswritten)
    }

    static func state(fromStatus status: UInt32) -> ProcessState {
        switch Int32(truncatingIfNeeded: status) {
        case SIDL: return .idle
        case SRUN: return .running
        case SSLEEP: return .sleeping
        case SSTOP: return .stopped
        case SZOMB: return .zombie
        default: return .unknown
        }
    }

    // MARK: Sockets

    public func sockets() throws -> [SocketRecord] {
        var records: [SocketRecord] = []
        for pid in try processIdentifiers() {
            records.append(contentsOf: sockets(ofProcess: pid))
        }
        return records
    }

    /// Empty for a process whose descriptors this caller may not read, which is every
    /// process of another user. Internal rather than private so a test can point it at the
    /// test process alone.
    func sockets(ofProcess pid: Int32) -> [SocketRecord] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }

        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = proc_pidinfo(
            pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return [] }

        var records: [SocketRecord] = []
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size
            else { continue }
            if let record = Self.socketRecord(from: info.psi, pid: pid) {
                records.append(record)
            }
        }
        return records
    }

    private static func socketRecord(from info: socket_info, pid: Int32) -> SocketRecord? {
        if info.soi_kind == Int32(SOCKINFO_TCP) {
            let tcp = info.soi_proto.pri_tcp
            return SocketRecord(
                pid: pid, transport: .tcp, localAddress: address(of: tcp.tcpsi_ini, local: true),
                localPort: port(of: tcp.tcpsi_ini, local: true),
                remoteAddress: address(of: tcp.tcpsi_ini, local: false),
                remotePort: port(of: tcp.tcpsi_ini, local: false),
                state: tcpStateName(tcp.tcpsi_state))
        }
        if info.soi_kind == Int32(SOCKINFO_IN), info.soi_protocol == Int32(IPPROTO_UDP) {
            let udp = info.soi_proto.pri_in
            return SocketRecord(
                pid: pid, transport: .udp, localAddress: address(of: udp, local: true),
                localPort: port(of: udp, local: true),
                remoteAddress: address(of: udp, local: false),
                remotePort: port(of: udp, local: false), state: nil)
        }
        return nil
    }

    private static func port(of info: in_sockinfo, local: Bool) -> Int {
        // The port is stored in network byte order in the low 16 bits of an int.
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: local ? info.insi_lport : info.insi_fport)))
    }

    private static func address(of info: in_sockinfo, local: Bool) -> String {
        // The local and remote addresses are two distinct imported union types, so each
        // is read where it is chosen.
        if info.insi_vflag & UInt8(INI_IPV6) != 0 {
            var address = local ? info.insi_laddr.ina_6 : info.insi_faddr.ina_6
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
                return "?"
            }
            return SystemCalls.string(fromCChars: buffer)
        }
        let raw = local ? info.insi_laddr.ina_46.i46a_addr4.s_addr : info.insi_faddr.ina_46.i46a_addr4.s_addr
        let host = UInt32(bigEndian: raw)
        return "\(host >> 24).\((host >> 16) & 0xff).\((host >> 8) & 0xff).\(host & 0xff)"
    }

    static func tcpStateName(_ state: Int32) -> String {
        switch state {
        case TSI_S_CLOSED: return "CLOSED"
        case TSI_S_LISTEN: return "LISTEN"
        case TSI_S_SYN_SENT: return "SYN_SENT"
        case TSI_S_SYN_RECEIVED: return "SYN_RECEIVED"
        case TSI_S_ESTABLISHED: return "ESTABLISHED"
        case TSI_S__CLOSE_WAIT: return "CLOSE_WAIT"
        case TSI_S_FIN_WAIT_1: return "FIN_WAIT_1"
        case TSI_S_CLOSING: return "CLOSING"
        case TSI_S_LAST_ACK: return "LAST_ACK"
        case TSI_S_FIN_WAIT_2: return "FIN_WAIT_2"
        case TSI_S_TIME_WAIT: return "TIME_WAIT"
        default: return "UNKNOWN(\(state))"
        }
    }
}
