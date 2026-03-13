import Foundation

let engine = CollectionEngine { count in
    if count % 10 == 0 {
        hrLog("\u{1F4CA}", "Collector", "Samples collected: \(count)")
    }
}

// Handle SIGTERM (launchctl unload) and SIGINT (Ctrl+C)
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        engine.stop()
        exit(0)
    }
    source.resume()
}

// Rotate log if > 5MB
let logPath = HeadroomPaths.databaseDirectory.appendingPathComponent("collector.log")
if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath.path),
   let size = attrs[.size] as? Int, size > 5_000_000 {
    let old = logPath.deletingLastPathComponent().appendingPathComponent("collector.log.old")
    try? FileManager.default.removeItem(at: old)
    try? FileManager.default.moveItem(at: logPath, to: old)
}

engine.start { success in
    if !success { exit(1) }
}

dispatchMain()
