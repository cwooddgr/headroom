import Foundation
import Darwin

// libproc declarations
@_silgen_name("proc_listpids")
func proc_listpids(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidinfo")
func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidpath")
func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

@_silgen_name("proc_name")
func proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

// Constants
private let PROC_ALL_PIDS: UInt32 = 1
private let PROC_PIDTASKINFO: Int32 = 4
private let MAXPATHLEN: Int = 1024

// proc_taskinfo layout matching Darwin's proc_taskinfo struct
struct ProcTaskInfo {
    var pti_virtual_size: UInt64 = 0
    var pti_resident_size: UInt64 = 0
    var pti_total_user: UInt64 = 0
    var pti_total_system: UInt64 = 0
    var pti_threads_user: UInt64 = 0
    var pti_threads_system: UInt64 = 0
    var pti_policy: Int32 = 0
    var pti_faults: Int32 = 0
    var pti_pageins: Int32 = 0
    var pti_cow_faults: Int32 = 0
    var pti_messages_sent: Int32 = 0
    var pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32 = 0
    var pti_syscalls_unix: Int32 = 0
    var pti_csw: Int32 = 0
    var pti_threadnum: Int32 = 0
    var pti_numrunning: Int32 = 0
    var pti_priority: Int32 = 0
}

struct ProcessEntry {
    let pid: Int32
    let name: String
    let cpuPct: Double
    let memoryBytes: Int64
}

// Mach timebase info (logged once at startup for diagnostics)
private let machTimebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    hrLog("\u{23F1}\u{FE0F}", "Process", "mach_timebase numer=\(info.numer) denom=\(info.denom)")
    return info
}()

final class ProcessSnapshot {
    // Raw snapshot data for CPU delta computation
    private struct RawInfo {
        let name: String
        let totalCPU: UInt64 // Mach absolute time ticks
        let memoryBytes: Int64
    }

    func captureTopProcesses(count: Int = 15) -> [ProcessEntry] {
        // Force timebase evaluation on first call
        _ = machTimebaseInfo

        // Take two snapshots 1 second apart to compute instantaneous CPU %
        let snap1 = captureRaw()
        let t1 = mach_absolute_time()
        Thread.sleep(forTimeInterval: 1.0)
        let snap2 = captureRaw()
        let t2 = mach_absolute_time()

        // Wall time in the same Mach absolute time units as pti_total_user/system
        let wallTicks = Double(t2 - t1)
        guard wallTicks > 0 else { return [] }

        var entries: [ProcessEntry] = []

        for (pid, info2) in snap2 {
            guard let info1 = snap1[pid] else { continue }
            guard info2.totalCPU >= info1.totalCPU else { continue }

            let deltaCPU = Double(info2.totalCPU - info1.totalCPU)
            // Both deltaCPU and wallTicks are in Mach absolute time units
            let cpuPct = deltaCPU / wallTicks * 100.0

            entries.append(ProcessEntry(
                pid: pid,
                name: info2.name,
                cpuPct: cpuPct,
                memoryBytes: info2.memoryBytes
            ))
        }

        // Log top process for debugging
        if let top = entries.max(by: { $0.cpuPct < $1.cpuPct }) {
            hrLog("\u{2699}\u{FE0F}", "Process", "top='\(top.name)' \(String(format: "%.1f", top.cpuPct))% | \(entries.count) procs sampled")
        }

        // Sort by memory (more stable metric), take top N
        entries.sort { $0.memoryBytes > $1.memoryBytes }
        return Array(entries.prefix(count))
    }

    private func captureRaw() -> [Int32: RawInfo] {
        let pidBufSize = proc_listpids(PROC_ALL_PIDS, 0, nil, 0)
        guard pidBufSize > 0 else { return [:] }

        let pidCount = Int(pidBufSize) / MemoryLayout<Int32>.size
        var pids = [Int32](repeating: 0, count: pidCount)
        let actualSize = proc_listpids(PROC_ALL_PIDS, 0, &pids, pidBufSize)
        let actualCount = Int(actualSize) / MemoryLayout<Int32>.size
        guard actualCount > 0 else { return [:] }

        var result: [Int32: RawInfo] = [:]

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var taskInfo = ProcTaskInfo()
            let taskInfoSize = Int32(MemoryLayout<ProcTaskInfo>.size)
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)
            guard ret == taskInfoSize else { continue }

            var pathBuffer = [CChar](repeating: 0, count: MAXPATHLEN)
            let pathResult = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))

            let name: String
            if pathResult > 0 {
                let fullPath = String(cString: pathBuffer)
                name = (fullPath as NSString).lastPathComponent
            } else {
                var nameBuffer = [CChar](repeating: 0, count: MAXPATHLEN)
                _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                let n = String(cString: nameBuffer)
                if n.isEmpty { continue }
                name = n
            }

            guard !name.isEmpty else { continue }

            result[pid] = RawInfo(
                name: name,
                totalCPU: taskInfo.pti_total_user + taskInfo.pti_total_system,
                memoryBytes: Int64(taskInfo.pti_resident_size)
            )
        }

        return result
    }
}
