import Foundation

private let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func hrLog(_ emoji: String, _ tag: String, _ message: String) {
    let ts = logDateFormatter.string(from: Date())
    print("\(emoji) [\(ts)] \(tag): \(message)")
}
