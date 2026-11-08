import Foundation

/// 诊断日志：同时写到系统日志和 ~/Library/Logs/MenuBar.log
func debugLog(_ message: String) {
    NSLog("MenuBar: %@", message)
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MenuBar.log")
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}
