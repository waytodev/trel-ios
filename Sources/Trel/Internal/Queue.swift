import Foundation

/// Disk-backed queue at `Application Support/trel/queue/<ulid>.<logs|traces>.json`. Each file is
/// one OTLP export body. Records batch in memory (100 records or 2 s) before hitting disk; the crash
/// path bypasses batching with `writeLogsNow`.
final class Queue {
    let dir: URL
    private let lock = NSLock()
    private var pendingLogs: [[String: Any]] = []
    private var pendingSpans: [[String: Any]] = []
    private let resource: Resource

    var onDirty: (() -> Void)?

    private static let batchSize = 100
    private static let maxFiles = 200
    private static let maxBytes = 8 * 1024 * 1024
    /// Present only in fatal records; protects them from trimming and flags a crashed session.
    private static let fatalMarker = "\"exception.escaped\""

    init(resource: Resource) {
        self.resource = resource
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("trel/queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func enqueueLog(_ record: [String: Any]) {
        lock.lock()
        pendingLogs.append(record)
        let flush = pendingLogs.count >= Queue.batchSize
        lock.unlock()
        if flush { flushMemory() } else { onDirty?() }
    }

    func enqueueSpan(_ span: [String: Any]) {
        lock.lock()
        pendingSpans.append(span)
        let flush = pendingSpans.count >= Queue.batchSize
        lock.unlock()
        if flush { flushMemory() } else { onDirty?() }
    }

    func flushMemory() {
        lock.lock()
        let logs = pendingLogs; pendingLogs.removeAll()
        let spans = pendingSpans; pendingSpans.removeAll()
        lock.unlock()
        if !logs.isEmpty { writeLogsNow(logs) }
        if !spans.isEmpty { write(kind: "traces", body: Otlp.tracesBody(resource: resource.attributes(), spans: spans)) }
    }

    func writeLogsNow(_ records: [[String: Any]]) {
        write(kind: "logs", body: Otlp.logsBody(resource: resource.attributes(), records: records))
    }

    private func write(kind: String, body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let tmp = dir.appendingPathComponent("\(Ids.ulid()).\(kind).tmp")
        let target = tmp.deletingPathExtension().appendingPathExtension("json")
        do {
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.moveItem(at: tmp, to: target)
            trimIfNeeded()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Trel.debugLog("queue write failed: \(error)")
        }
    }

    func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return all.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func hasCrashEnvelope() -> Bool { files().contains(where: isCrashFile) }

    private func isCrashFile(_ url: URL) -> Bool {
        guard url.lastPathComponent.hasSuffix(".logs.json"), let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(Queue.fatalMarker) && text.contains("\"boolValue\":true")
    }

    private func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func trimIfNeeded() {
        let list = files()
        var count = list.count
        var bytes = list.reduce(0) { $0 + size($1) }
        guard count > Queue.maxFiles || bytes > Queue.maxBytes else { return }
        for f in list {
            if count <= Queue.maxFiles && bytes <= Queue.maxBytes { break }
            if isCrashFile(f) { continue }
            bytes -= size(f)
            count -= 1
            try? FileManager.default.removeItem(at: f)
        }
    }
}
