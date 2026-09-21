import Foundation

/// Disk queue for screenshots, replay frames, and profiles. Uploaded beside the OTLP queue.
final class Attachments {
    let dir: URL
    private let lock = NSLock()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("trel/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func enqueue(type: String, body: Data, eventId: String?, traceId: String?, sessionId: String?, fatal: Bool, id forced: String? = nil) -> String {
        let cap = type == "profile" ? 1024 * 1024 : 200 * 1024
        let bytes = body.prefix(cap)
        let id = (forced?.isEmpty == false ? forced! : UUID().uuidString.lowercased())
        var meta: [String: Any] = ["id": id, "type": type, "ts": Int(Date().timeIntervalSince1970 * 1000), "fatal": fatal]
        if let eventId = eventId { meta["eventId"] = eventId }
        if let traceId = traceId { meta["traceId"] = traceId }
        if let sessionId = sessionId { meta["sessionId"] = sessionId }
        lock.lock()
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: dir.appendingPathComponent("\(id).json"))
            try? Data(bytes).write(to: dir.appendingPathComponent("\(id).bin"))
        }
        lock.unlock()
        if !fatal { trim() }
        Trel.shared?.transport.scheduleSoon(2)
        return id
    }

    func pending() -> [(meta: [String: Any], file: URL)] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { metaURL in
            guard let data = try? Data(contentsOf: metaURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String else { return nil }
            let bin = dir.appendingPathComponent("\(id).bin")
            guard FileManager.default.fileExists(atPath: bin.path) else { return nil }
            return (obj, bin)
        }
    }

    func delete(id: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).bin"))
    }

    private func trim() {
        let bins = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "bin" }
        var total = bins.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard bins.count > 40 || total > 8 * 1024 * 1024 else { return }
        for url in bins {
            let id = url.deletingPathExtension().lastPathComponent
            delete(id: id)
            total -= (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if total < 6 * 1024 * 1024 { break }
        }
    }
}
