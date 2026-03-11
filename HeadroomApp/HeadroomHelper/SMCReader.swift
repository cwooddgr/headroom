import Foundation
import IOKit

final class SMCReader {
    private var connection: io_connect_t = 0
    private var isOpen = false

    // Dynamically discovered temperature keys
    private var cpuTempKeys: [String] = []
    private var gpuTempKeys: [String] = []

    // SMC struct layout (80 bytes, matching macmon's KeyData #[repr(C)]):
    //   key: u32              @ 0   (4 bytes)
    //   vers: KeyDataVer      @ 4   (6 bytes + 2 pad)
    //   pLimitData: PLimitData@ 12  (16 bytes)
    //   keyInfo.dataSize: u32 @ 28  (4 bytes)
    //   keyInfo.dataType: u32 @ 32  (4 bytes)
    //   keyInfo.dataAttr: u8  @ 36  (1 byte + 3 pad)
    //   result: u8            @ 40
    //   status: u8            @ 41
    //   data8 (command): u8   @ 42
    //   pad: 1 byte           @ 43
    //   data32: u32           @ 44
    //   bytes: [u8; 32]       @ 48

    private let structSize = 80
    private let offKeyInfoDataSize = 28
    private let offKeyInfoDataType = 32
    private let offCommand = 42
    private let offData32 = 44
    private let offBytes = 48

    private let cmdReadKeyInfo: UInt8 = 9
    private let cmdReadBytes: UInt8 = 5
    private let cmdGetKeyByIndex: UInt8 = 8
    private let selectorIndex: UInt32 = 2

    // FourCC "flt " as big-endian u32
    private let typeFloat: UInt32 = 0x666C7420

    init() {
        openConnection()
        if isOpen {
            discoverTemperatureKeys()
        }
    }

    deinit {
        closeConnection()
    }

    // MARK: - Connection

    private func openConnection() {
        // macmon connects to "AppleSMCKeysEndpoint", a child of the AppleSMC driver
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceNameMatching("AppleSMC"),
            &iter
        ) == kIOReturnSuccess else {
            print("SMCReader: No AppleSMC services found")
            return
        }
        defer { IOObjectRelease(iter) }

        var entry = IOIteratorNext(iter)
        while entry != 0 {
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)

            if name == "AppleSMCKeysEndpoint" {
                let result = IOServiceOpen(entry, mach_task_self_, 0, &connection)
                IOObjectRelease(entry)
                if result == kIOReturnSuccess {
                    isOpen = true
                    print("SMCReader: Connected to AppleSMCKeysEndpoint")
                } else {
                    print("SMCReader: Failed to open AppleSMCKeysEndpoint: 0x\(String(result, radix: 16))")
                }
                return
            }

            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }

        // Fallback: open AppleSMC directly (older macOS)
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else {
            print("SMCReader: AppleSMC not found")
            return
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result == kIOReturnSuccess {
            isOpen = true
            print("SMCReader: Connected to AppleSMC (fallback)")
        } else {
            print("SMCReader: Failed to open AppleSMC: 0x\(String(result, radix: 16))")
        }
    }

    private func closeConnection() {
        if isOpen {
            IOServiceClose(connection)
            isOpen = false
        }
    }

    // MARK: - Key Discovery

    private func discoverTemperatureKeys() {
        let totalKeys = getKeyCount()
        print("SMCReader: Total SMC keys: \(totalKeys)")

        for i in 0..<totalKeys {
            guard let key = getKeyAtIndex(i) else { continue }
            guard key.hasPrefix("T") else { continue }

            // Get key info to check type
            guard let info = readKeyInfo(key) else { continue }

            // Only read "flt " type keys (f32 little-endian temperature sensors)
            guard info.dataType == typeFloat, info.dataSize == 4 else { continue }

            // Try reading the value
            guard let temp = readFloatKey(key), temp > 0 && temp < 130 else { continue }

            if key.hasPrefix("Tp") || key.hasPrefix("Tc") || key.hasPrefix("Te") {
                cpuTempKeys.append(key)
            } else if key.hasPrefix("Tg") {
                gpuTempKeys.append(key)
            }
        }

        print("SMCReader: CPU temp keys (\(cpuTempKeys.count)): \(cpuTempKeys)")
        print("SMCReader: GPU temp keys (\(gpuTempKeys.count)): \(gpuTempKeys)")
    }

    // MARK: - Temperature Reading

    func readCPUTemperature() -> Double {
        guard isOpen, !cpuTempKeys.isEmpty else {
            return thermalStateFallbackTemp()
        }

        var temps: [Double] = []
        for key in cpuTempKeys {
            if let temp = readFloatKey(key), temp > 0 && temp < 130 {
                temps.append(Double(temp))
            }
        }

        if temps.isEmpty {
            return thermalStateFallbackTemp()
        }
        return temps.reduce(0, +) / Double(temps.count)
    }

    func readGPUTemperature() -> Double {
        guard isOpen, !gpuTempKeys.isEmpty else {
            return thermalStateFallbackTemp() * 0.9
        }

        var temps: [Double] = []
        for key in gpuTempKeys {
            if let temp = readFloatKey(key), temp > 0 && temp < 130 {
                temps.append(Double(temp))
            }
        }

        if temps.isEmpty {
            return thermalStateFallbackTemp() * 0.9
        }
        return temps.reduce(0, +) / Double(temps.count)
    }

    // MARK: - Low-Level SMC Access

    private struct KeyInfoResult {
        let dataSize: UInt32
        let dataType: UInt32
    }

    private func smcCall(_ input: inout [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: structSize)
        var outputSize = structSize
        let result = IOConnectCallStructMethod(
            connection,
            selectorIndex,
            &input,
            structSize,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else { return nil }
        return output
    }

    private func setKey(_ input: inout [UInt8], _ key: String) {
        let bytes = Array(key.utf8)
        for i in 0..<min(4, bytes.count) {
            input[i] = bytes[i]
        }
    }

    private func getKeyCount() -> UInt32 {
        var input = [UInt8](repeating: 0, count: structSize)
        setKey(&input, "#KEY")
        input[offCommand] = cmdReadKeyInfo
        guard let output = smcCall(&input) else { return 0 }

        // Copy key info back for read
        for i in offKeyInfoDataSize..<(offKeyInfoDataSize + 9) {
            input[i] = output[i]
        }
        input[offCommand] = cmdReadBytes
        guard let output2 = smcCall(&input) else { return 0 }

        // Key count as big-endian u32 at bytes offset
        let b = offBytes
        return UInt32(output2[b]) << 24 | UInt32(output2[b+1]) << 16 |
               UInt32(output2[b+2]) << 8 | UInt32(output2[b+3])
    }

    private func getKeyAtIndex(_ index: UInt32) -> String? {
        var input = [UInt8](repeating: 0, count: structSize)
        input[offCommand] = cmdGetKeyByIndex
        // Index goes in data32 field (big-endian u32 at offset 44)
        input[offData32] = UInt8((index >> 24) & 0xFF)
        input[offData32 + 1] = UInt8((index >> 16) & 0xFF)
        input[offData32 + 2] = UInt8((index >> 8) & 0xFF)
        input[offData32 + 3] = UInt8(index & 0xFF)

        guard let output = smcCall(&input) else { return nil }
        // Key name is in the first 4 bytes of output
        let bytes = [output[0], output[1], output[2], output[3]]
        guard bytes.allSatisfy({ $0 > 0 }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    private func readKeyInfo(_ key: String) -> KeyInfoResult? {
        var input = [UInt8](repeating: 0, count: structSize)
        setKey(&input, key)
        input[offCommand] = cmdReadKeyInfo
        guard let output = smcCall(&input) else { return nil }

        let dataSize = UInt32(output[offKeyInfoDataSize]) << 24 |
                        UInt32(output[offKeyInfoDataSize + 1]) << 16 |
                        UInt32(output[offKeyInfoDataSize + 2]) << 8 |
                        UInt32(output[offKeyInfoDataSize + 3])
        let dataType = UInt32(output[offKeyInfoDataType]) << 24 |
                        UInt32(output[offKeyInfoDataType + 1]) << 16 |
                        UInt32(output[offKeyInfoDataType + 2]) << 8 |
                        UInt32(output[offKeyInfoDataType + 3])

        guard dataSize > 0 && dataSize <= 32 else { return nil }
        return KeyInfoResult(dataSize: dataSize, dataType: dataType)
    }

    private func readFloatKey(_ key: String) -> Float? {
        var input = [UInt8](repeating: 0, count: structSize)
        setKey(&input, key)

        // Get key info first
        input[offCommand] = cmdReadKeyInfo
        guard let infoOutput = smcCall(&input) else { return nil }

        // Copy key info into input for read
        for i in offKeyInfoDataSize..<(offKeyInfoDataSize + 9) {
            input[i] = infoOutput[i]
        }

        // Read value
        input[offCommand] = cmdReadBytes
        guard let output = smcCall(&input) else { return nil }

        // f32 little-endian at bytes offset
        let b = offBytes
        let raw = UInt32(output[b]) | UInt32(output[b+1]) << 8 |
                  UInt32(output[b+2]) << 16 | UInt32(output[b+3]) << 24
        return Float(bitPattern: raw)
    }

    private func thermalStateFallbackTemp() -> Double {
        let state = Foundation.ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal: return 45.0
        case .fair: return 65.0
        case .serious: return 85.0
        case .critical: return 100.0
        @unknown default: return 55.0
        }
    }
}
