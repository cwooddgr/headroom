import Foundation

struct ProcessEntry {
    let pid: Int32
    let name: String
    let cpuPct: Double
    let memoryBytes: Int64
}

final class ProcessSnapshot {

    func captureTopProcesses(count: Int = 15) -> [ProcessEntry] {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,rss=,pcpu=,comm="]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            hrLog("⚠️", "Process", "ps failed: \(error)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var entries: [ProcessEntry] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Format: PID  RSS  %CPU  COMMAND_PATH
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let rssKB = Int64(parts[1]),
                  let cpuPct = Double(parts[2]) else { continue }

            guard pid > 0 else { continue }

            let name = (String(parts[3]) as NSString).lastPathComponent
            guard !name.isEmpty else { continue }

            let memoryBytes = rssKB * 1024

            // Noise filter: skip near-zero processes
            if cpuPct < 0.1 && memoryBytes < 10 * 1024 * 1024 {
                continue
            }

            entries.append(ProcessEntry(
                pid: pid,
                name: name,
                cpuPct: cpuPct,
                memoryBytes: memoryBytes
            ))
        }

        // Log top process for debugging
        if let top = entries.max(by: { $0.cpuPct < $1.cpuPct }) {
            hrLog("⚙️", "Process", "top='\(top.name)' \(String(format: "%.1f", top.cpuPct))% | \(entries.count) procs sampled")
        }

        // Sort by combined CPU + memory weight
        entries.sort { a, b in
            let weightA = a.cpuPct + Double(a.memoryBytes) / (1024.0 * 1024.0)
            let weightB = b.cpuPct + Double(b.memoryBytes) / (1024.0 * 1024.0)
            return weightA > weightB
        }
        return Array(entries.prefix(count))
    }
}
