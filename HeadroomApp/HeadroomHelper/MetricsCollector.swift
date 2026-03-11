import Foundation
import IOKit

// MARK: - IOReport Dynamic Symbol Loading

// Try multiple approaches: explicit IOKit path, then RTLD_DEFAULT (shared cache)
nonisolated(unsafe) private let iokitHandle: UnsafeMutableRawPointer? = {
    if let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) {
        return h
    }
    if let h = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_NOW) {
        return h
    }
    // On macOS 15+, frameworks live in shared cache — use RTLD_DEFAULT via nil handle
    return nil
}()

private func loadSym<T>(_ name: String) -> T? {
    // Try explicit handle first, then RTLD_DEFAULT for shared cache
    if let handle = iokitHandle, let ptr = dlsym(handle, name) {
        return unsafeBitCast(ptr, to: T.self)
    }
    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { // RTLD_DEFAULT
        return unsafeBitCast(ptr, to: T.self)
    }
    return nil
}

// IOReport function type aliases
private typealias CopyChannelsFn = @convention(c) (
    CFString, CFString?, UInt64, UInt64, UInt64
) -> Unmanaged<CFDictionary>?

private typealias MergeChannelsFn = @convention(c) (
    CFMutableDictionary, CFDictionary, UnsafeRawPointer?
) -> Void

private typealias CreateSubscriptionFn = @convention(c) (
    UnsafeRawPointer?, CFMutableDictionary,
    UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
    UInt64, UnsafeRawPointer?
) -> UnsafeRawPointer?

private typealias CreateSamplesFn = @convention(c) (
    UnsafeRawPointer, CFMutableDictionary, UnsafeRawPointer?
) -> Unmanaged<CFDictionary>?

private typealias CreateSamplesDeltaFn = @convention(c) (
    CFDictionary, CFDictionary, UnsafeRawPointer?
) -> Unmanaged<CFDictionary>?

private typealias IterateFn = @convention(c) (
    CFDictionary, @convention(block) (CFDictionary) -> Int32
) -> Void

private typealias SimpleGetIntFn = @convention(c) (CFDictionary, Int32) -> Int64

private typealias StateGetCountFn = @convention(c) (CFDictionary) -> Int32
private typealias StateGetResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64

private typealias ChannelGetStrFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias StateGetNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

// Loaded symbols (nil if unavailable)
private let _copyChannels: CopyChannelsFn? = loadSym("IOReportCopyChannelsInGroup")
private let _mergeChannels: MergeChannelsFn? = loadSym("IOReportMergeChannels")
private let _createSubscription: CreateSubscriptionFn? = loadSym("IOReportCreateSubscription")
private let _createSamples: CreateSamplesFn? = loadSym("IOReportCreateSamples")
private let _createSamplesDelta: CreateSamplesDeltaFn? = loadSym("IOReportCreateSamplesDelta")
private let _iterate: IterateFn? = loadSym("IOReportIterate")
private let _simpleGetInt: SimpleGetIntFn? = loadSym("IOReportSimpleGetIntegerValue")
private let _stateGetCount: StateGetCountFn? = loadSym("IOReportStateGetCount")
private let _stateGetResidency: StateGetResidencyFn? = loadSym("IOReportStateGetResidency")
private let _stateGetName: StateGetNameFn? = loadSym("IOReportStateGetNameForIndex")
private let _channelGetGroup: ChannelGetStrFn? = loadSym("IOReportChannelGetGroup")
private let _channelGetSubGroup: ChannelGetStrFn? = loadSym("IOReportChannelGetSubGroup")
private let _channelGetName: ChannelGetStrFn? = loadSym("IOReportChannelGetChannelName")

// MARK: - MetricsCollector

final class MetricsCollector {
    private var subscription: UnsafeRawPointer?
    private var subscriptionChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private let smcReader = SMCReader()
    private let ioReportAvailable: Bool

    // DVFS frequency tables (MHz values per state index)
    private var eClusterFreqsMHz: [Double] = []
    private var pClusterFreqsMHz: [Double] = []
    private var gpuFreqsMHz: [Double] = []

    init() {
        ioReportAvailable = _copyChannels != nil && _createSubscription != nil
        if ioReportAvailable {
            loadDVFSFrequencyTables()
            setupIOReportSubscription()
        } else {
            hrLog("\u{26A0}\u{FE0F}", "Metrics", "IOReport unavailable, using fallback metrics")
        }
    }

    // MARK: - DVFS Frequency Table Loading

    private func loadDVFSFrequencyTables() {
        // Find the pmgr node in the IOKit registry
        guard let matching = IOServiceNameMatching("pmgr") else {
            hrLog("\u{26A0}\u{FE0F}", "Metrics", "Could not create pmgr matching dict")
            return
        }

        let pmgr = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard pmgr != 0 else {
            hrLog("\u{26A0}\u{FE0F}", "Metrics", "pmgr IOService not found")
            return
        }
        defer { IOObjectRelease(pmgr) }

        // Detect generation for frequency scaling:
        // M1/M2/M3 store frequencies in Hz, M4+ in kHz
        var chipName = ""
        var sz = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &sz, nil, 0)
        if sz > 0 {
            var buf = [CChar](repeating: 0, count: sz)
            sysctlbyname("machdep.cpu.brand_string", &buf, &sz, nil, 0)
            chipName = String(cString: buf)
        }
        // M4 and later use kHz; M1/M2/M3 use Hz
        let isM4OrLater = chipName.contains("M4") || chipName.contains("M5") ||
                          chipName.contains("M6") || chipName.contains("M7")
        let divisor: Double = isM4OrLater ? 1_000.0 : 1_000_000.0

        eClusterFreqsMHz = readFrequencyTable(from: pmgr, key: "voltage-states1-sram", divisor: divisor)
        pClusterFreqsMHz = readFrequencyTable(from: pmgr, key: "voltage-states5-sram", divisor: divisor)
        gpuFreqsMHz = readFrequencyTable(from: pmgr, key: "voltage-states9-sram", divisor: divisor)

        hrLog("\u{1F4CA}", "Metrics", "DVFS tables: E-cluster=\(eClusterFreqsMHz.count) states, P-cluster=\(pClusterFreqsMHz.count) states, GPU=\(gpuFreqsMHz.count) states")
        if !eClusterFreqsMHz.isEmpty {
            hrLog("\u{1F4CA}", "Metrics", "E-cluster freqs: \(eClusterFreqsMHz.map { Int($0) }) MHz")
        }
        if !pClusterFreqsMHz.isEmpty {
            hrLog("\u{1F4CA}", "Metrics", "P-cluster freqs: \(pClusterFreqsMHz.map { Int($0) }) MHz")
        }
        if !gpuFreqsMHz.isEmpty {
            hrLog("\u{1F4CA}", "Metrics", "GPU freqs: \(gpuFreqsMHz.map { Int($0) }) MHz")
        }
    }

    private func readFrequencyTable(from service: io_service_t, key: String, divisor: Double) -> [Double] {
        guard let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return []
        }
        guard let data = prop.takeRetainedValue() as? Data else { return [] }

        // Data is array of (UInt32 freq, UInt32 voltage) pairs, little-endian
        let pairSize = 8 // 4 bytes freq + 4 bytes voltage
        let count = data.count / pairSize
        var freqs: [Double] = []

        for i in 0..<count {
            let offset = i * pairSize
            let freqRaw: UInt32 = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: offset, as: UInt32.self)
            }
            let freqMHz = Double(freqRaw) / divisor
            if freqMHz > 0 {
                freqs.append(freqMHz)
            }
        }
        return freqs
    }

    // MARK: - IOReport Setup

    private func setupIOReportSubscription() {
        let groups = ["CPU Stats", "GPU Stats", "Energy Model"]
        var allChannels: CFMutableDictionary?

        for group in groups {
            guard let channels = _copyChannels?(
                group as CFString, nil, 0, 0, 0
            )?.takeRetainedValue() else {
                hrLog("\u{26A0}\u{FE0F}", "Metrics", "No channels for group '\(group)'")
                continue
            }
            hrLog("\u{2705}", "Metrics", "Found channels for group '\(group)'")

            if allChannels == nil {
                allChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels)
            } else {
                _mergeChannels?(allChannels!, channels, nil)
            }
        }

        guard let channels = allChannels else {
            hrLog("\u{274C}", "Metrics", "Failed to discover IOReport channels")
            return
        }

        var subsPtr: Unmanaged<CFMutableDictionary>?
        subscription = _createSubscription?(nil, channels, &subsPtr, 0, nil)
        subscriptionChannels = subsPtr?.takeRetainedValue()

        if subscription == nil {
            hrLog("\u{274C}", "Metrics", "Failed to create IOReport subscription")
        } else {
            hrLog("\u{2705}", "Metrics", "IOReport subscription created")
        }
    }

    // MARK: - Sample Collection

    struct MetricsSample {
        var cpuEClusterPct: Double = 0
        var cpuPClusterPct: Double = 0
        var cpuFreqE: Int = 0
        var cpuFreqP: Int = 0
        var cpuPowerWatts: Double = 0
        var gpuUtilizationPct: Double = 0
        var gpuFreqMhz: Int = 0
        var gpuPowerWatts: Double = 0
        var anePowerWatts: Double = 0
        var memorySwapUsedBytes: Int64 = 0
        var memoryPressure: String = "normal"
        var memoryCompressedBytes: Int64 = 0
        var memoryPageins: Int64 = 0
        var memoryPageouts: Int64 = 0
        var thermalPressure: String = "nominal"
        var cpuTempAvg: Double = 0
        var gpuTempAvg: Double = 0
        var packagePowerWatts: Double = 0
        var sysPowerWatts: Double = 0
    }

    func collectSample() -> MetricsSample {
        var sample = MetricsSample()

        // IOReport metrics (CPU/GPU utilization, power)
        if ioReportAvailable {
            collectIOReportMetrics(&sample)
        }
        // Fallback if IOReport unavailable or returned no CPU data
        if sample.cpuEClusterPct == 0 && sample.cpuPClusterPct == 0 {
            collectFallbackCPUMetrics(&sample)
        }

        // Memory stats via Mach API
        collectMemoryStats(&sample)

        // Memory pressure
        sample.memoryPressure = readMemoryPressure()

        // Swap usage
        sample.memorySwapUsedBytes = readSwapUsage()

        // Temperatures via SMC
        sample.cpuTempAvg = smcReader.readCPUTemperature()
        sample.gpuTempAvg = smcReader.readGPUTemperature()

        // Derive thermal pressure from CPU temp
        sample.thermalPressure = deriveThermalPressure(cpuTemp: sample.cpuTempAvg)

        // CPU/GPU frequencies come from IOReport (collectIOReportMetrics sets them)
        // No additional frequency reading needed

        return sample
    }

    // MARK: - IOReport Collection

    private func collectIOReportMetrics(_ sample: inout MetricsSample) {
        guard let sub = subscription, let channels = subscriptionChannels else { return }

        guard let currentSample = _createSamples?(sub, channels, nil)?.takeRetainedValue() else {
            return
        }

        defer { previousSample = currentSample }

        guard let prev = previousSample else { return }

        guard let delta = _createSamplesDelta?(prev, currentSample, nil)?.takeRetainedValue() else {
            return
        }

        var eCoreUtils: [Double] = []
        var pCoreUtils: [Double] = []
        var gpuUtils: [Double] = []
        var cpuPower: Double = 0
        var gpuPower: Double = 0
        var anePower: Double = 0
        var packagePower: Double = 0

        // Frequency accumulators: weighted sum of (residency × freq) per cluster
        var eFreqWeightedSum: Double = 0
        var eFreqTotalResidency: Int64 = 0
        var pFreqWeightedSum: Double = 0
        var pFreqTotalResidency: Int64 = 0
        var gpuFreqWeightedSum: Double = 0
        var gpuFreqTotalResidency: Int64 = 0

        _iterate?(delta) { ch in
            let group = _channelGetGroup?(ch)?.takeUnretainedValue() as String? ?? ""
            let subGroup = _channelGetSubGroup?(ch)?.takeUnretainedValue() as String? ?? ""
            let name = _channelGetName?(ch)?.takeUnretainedValue() as String? ?? ""

            if group == "CPU Stats" || group == "GPU Stats" {
                let stateCount = _stateGetCount?(ch) ?? 0
                guard stateCount >= 2 else { return 0 }

                let isPerformanceStates = subGroup == "CPU Core Performance States" ||
                                          subGroup == "GPU Performance States"

                if isPerformanceStates {
                    // Frequency extraction from DVFS state residency
                    let freqTable: [Double]
                    let isECluster = name.contains("ECPU") || name.hasPrefix("E")
                    let isPCluster = name.contains("PCPU") || name.hasPrefix("P")
                    let isGPU = group == "GPU Stats"

                    if isECluster {
                        freqTable = self.eClusterFreqsMHz
                    } else if isPCluster {
                        freqTable = self.pClusterFreqsMHz
                    } else if isGPU {
                        freqTable = self.gpuFreqsMHz
                    } else {
                        freqTable = []
                    }

                    // Find IDLE/OFF state offset using state names
                    var idleOffset = 0
                    for s in 0..<stateCount {
                        if let stateName = _stateGetName?(ch, s)?.takeUnretainedValue() as String? {
                            let upper = stateName.uppercased()
                            if upper == "IDLE" || upper == "DOWN" || upper == "OFF" {
                                idleOffset = Int(s) + 1
                            }
                        }
                    }

                    var totalRes: Int64 = 0
                    var activeRes: Int64 = 0
                    var weightedFreq: Double = 0

                    for s in 0..<stateCount {
                        let r = _stateGetResidency?(ch, s) ?? 0
                        totalRes += r
                        if Int(s) >= idleOffset {
                            activeRes += r
                            // Map state index to frequency table
                            let freqIdx = Int(s) - idleOffset
                            if freqIdx >= 0 && freqIdx < freqTable.count {
                                weightedFreq += Double(r) * freqTable[freqIdx]
                            }
                        }
                    }

                    if totalRes > 0 && activeRes > 0 {
                        if isECluster {
                            eFreqWeightedSum += weightedFreq
                            eFreqTotalResidency += activeRes
                        } else if isPCluster {
                            pFreqWeightedSum += weightedFreq
                            pFreqTotalResidency += activeRes
                        } else if isGPU {
                            gpuFreqWeightedSum += weightedFreq
                            gpuFreqTotalResidency += activeRes
                        }
                    }
                } else {
                    // Utilization channels (existing logic)
                    var totalResidency: Int64 = 0
                    var activeResidency: Int64 = 0
                    for s in 0..<stateCount {
                        let r = _stateGetResidency?(ch, s) ?? 0
                        totalResidency += r
                        if s > 0 { activeResidency += r }
                    }
                    guard totalResidency > 0 else { return 0 }
                    let pct = Double(activeResidency) / Double(totalResidency) * 100.0

                    if group == "CPU Stats" {
                        if subGroup.contains("E-Cluster") || name.contains("ECPU") {
                            eCoreUtils.append(pct)
                        } else if subGroup.contains("P-Cluster") || name.contains("PCPU") {
                            pCoreUtils.append(pct)
                        }
                    } else {
                        gpuUtils.append(pct)
                    }
                }
            } else if group == "Energy Model" {
                let nanojoules = Double(_simpleGetInt?(ch, 0) ?? 0)
                let watts = nanojoules / 1_000_000_000.0 / 30.0 // nJ -> W over 30s

                if name.contains("CPU") && !name.contains("GPU") {
                    cpuPower += watts
                } else if name.contains("GPU") {
                    gpuPower += watts
                } else if name.contains("ANE") {
                    anePower += watts
                } else if name.lowercased().contains("package") {
                    packagePower = watts
                }
            }
            return 0
        }

        if !eCoreUtils.isEmpty {
            sample.cpuEClusterPct = eCoreUtils.reduce(0, +) / Double(eCoreUtils.count)
        }
        if !pCoreUtils.isEmpty {
            sample.cpuPClusterPct = pCoreUtils.reduce(0, +) / Double(pCoreUtils.count)
        }
        if !gpuUtils.isEmpty {
            sample.gpuUtilizationPct = gpuUtils.reduce(0, +) / Double(gpuUtils.count)
        }

        // Compute weighted average frequencies
        if eFreqTotalResidency > 0 {
            sample.cpuFreqE = Int(eFreqWeightedSum / Double(eFreqTotalResidency))
        }
        if pFreqTotalResidency > 0 {
            sample.cpuFreqP = Int(pFreqWeightedSum / Double(pFreqTotalResidency))
        }
        if gpuFreqTotalResidency > 0 {
            sample.gpuFreqMhz = Int(gpuFreqWeightedSum / Double(gpuFreqTotalResidency))
        }

        sample.cpuPowerWatts = cpuPower
        sample.gpuPowerWatts = gpuPower
        sample.anePowerWatts = anePower
        sample.packagePowerWatts = packagePower > 0 ? packagePower : cpuPower + gpuPower + anePower

        // System power from SMC PSTR key; use max of SMC reading and package power
        let smcSystemPower = smcReader.readSystemPower()
        sample.sysPowerWatts = max(smcSystemPower, sample.packagePowerWatts)
    }

    // MARK: - Fallback CPU Metrics (host_processor_info)

    private func collectFallbackCPUMetrics(_ sample: inout MetricsSample) {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<Int32>.size))
        }

        var totalUser: Double = 0, totalSystem: Double = 0, totalIdle: Double = 0
        for i in 0..<Int(cpuCount) {
            let offset = Int(CPU_STATE_MAX) * i
            totalUser += Double(info[offset + Int(CPU_STATE_USER)]) + Double(info[offset + Int(CPU_STATE_NICE)])
            totalSystem += Double(info[offset + Int(CPU_STATE_SYSTEM)])
            totalIdle += Double(info[offset + Int(CPU_STATE_IDLE)])
        }
        let totalAll = totalUser + totalSystem + totalIdle
        if totalAll > 0 {
            let usage = (totalUser + totalSystem) / totalAll * 100.0
            sample.cpuEClusterPct = usage
            sample.cpuPClusterPct = usage
        }
    }

    // MARK: - Memory Stats (Mach API)

    private func collectMemoryStats(_ sample: inout MetricsSample) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        var pageSizeValue: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSizeValue)
        let pageSize = Int64(pageSizeValue)
        sample.memoryPageins = Int64(stats.pageins)
        sample.memoryPageouts = Int64(stats.pageouts)
        sample.memoryCompressedBytes = Int64(stats.compressor_page_count) * pageSize
    }

    // MARK: - Memory Pressure

    private func readMemoryPressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return "normal"
        }
        switch level {
        case 4: return "critical"
        case 2: return "warn"
        default: return "normal"
        }
    }

    // MARK: - Swap Usage

    private func readSwapUsage() -> Int64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let ret = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        guard ret == 0 else {
            hrLog("\u{274C}", "Metrics", "vm.swapusage sysctl failed errno=\(errno)")
            return 0
        }
        let used = Int64(swap.xsu_used)
        if used > 0 {
            hrLog("\u{1F4A7}", "Swap", "total=\(swap.xsu_total / (1024*1024))MB used=\(used / (1024*1024))MB")
        }
        return used
    }

    // MARK: - Thermal Pressure

    private func deriveThermalPressure(cpuTemp: Double) -> String {
        if cpuTemp >= 95 { return "critical" }
        if cpuTemp >= 85 { return "heavy" }
        if cpuTemp >= 70 { return "moderate" }
        return "nominal"
    }
}
