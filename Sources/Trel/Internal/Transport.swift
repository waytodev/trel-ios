import Foundation
import zlib
#if canImport(UIKit)
import UIKit
#endif

/// Sends queued files to `/v1/logs` and `/v1/traces` on a serial queue: on start, 2 s after new
/// records, every 30 s while foregrounded, on network regain and on background. 5xx / 429 / IO →
/// exponential backoff (2 s … 5 min), keep file. Other 4xx → drop. 402 → stop for this process.
final class Transport {
    private let options: TrelOptions
    private let queue: Queue
    private let resource: Resource
    private let work = DispatchQueue(label: "to.trel.transport", qos: .utility)
    private let session: URLSession
    private var periodic: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var backoff: TimeInterval = 0
    private var nextAllowedAt = Date.distantPast
    private var sending = false
    private var disabled = false

    init(options: TrelOptions, queue: Queue, resource: Resource) {
        self.options = options
        self.queue = queue
        self.resource = resource
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    func start() {
        queue.onDirty = { [weak self] in self?.scheduleSoon(2.0) }
        scheduleSoon(0)
        setForeground(true)
    }

    func setForeground(_ foreground: Bool) {
        work.async { [self] in
            periodic?.cancel()
            periodic = nil
            if foreground {
                let t = DispatchSource.makeTimerSource(queue: work)
                t.schedule(deadline: .now() + 30, repeating: 30)
                t.setEventHandler { [weak self] in self?.send() }
                t.resume()
                periodic = t
            } else {
                sendInBackground()
            }
        }
    }

    func scheduleSoon(_ delay: TimeInterval) {
        work.async { [self] in
            debounce?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.send() }
            debounce = item
            work.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func flushBlocking(timeout: TimeInterval) {
        let group = DispatchGroup()
        group.enter()
        work.async { [self] in
            send(force: true)
            group.leave()
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    /// On background, ask for extra time so the queue drains before suspension.
    private func sendInBackground() {
        #if canImport(UIKit) && !os(tvOS)
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "to.trel.flush") {
            UIApplication.shared.endBackgroundTask(task)
        }
        send(force: true)
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        #else
        send(force: true)
        #endif
    }

    private enum Outcome { case sent, retry, drop, disabled }

    private func send(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(work))
        guard !disabled, !sending else { return }
        sending = true
        defer { sending = false }
        queue.flushMemory()
        if !force, Date() < nextAllowedAt { return }
        for file in queue.files() {
            if disabled { return }
            switch post(file) {
            case .sent:
                try? FileManager.default.removeItem(at: file)
                backoff = 0
            case .drop:
                try? FileManager.default.removeItem(at: file)
            case .retry:
                backoff = backoff == 0 ? 2 : min(backoff * 2, 300)
                nextAllowedAt = Date().addingTimeInterval(backoff)
                Trel.debugLog("send failed; retry in \(backoff)s")
                return
            case .disabled:
                disabled = true
                return
            }
        }
    }

    private func post(_ file: URL) -> Outcome {
        let path = file.lastPathComponent.hasSuffix(".traces.json") ? "/v1/traces" : "/v1/logs"
        guard let body = try? Data(contentsOf: file), !body.isEmpty else { return .drop }
        var request = URLRequest(url: options.endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(options.apiKey, forHTTPHeaderField: "x-trel-key")
        request.setValue(options.environment, forHTTPHeaderField: "x-trel-environment")
        request.setValue(resource.release, forHTTPHeaderField: "x-trel-release")
        request.setValue("\(Trel.sdkName)/\(Trel.sdkVersion)", forHTTPHeaderField: "x-trel-sdk")
        request.setValue("\(Trel.sdkName)/\(Trel.sdkVersion) (\(Resource.osName) \(Resource.osVersion))", forHTTPHeaderField: "User-Agent")
        if let gz = Gzip.compress(body) {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = gz
        } else {
            request.httpBody = body
        }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .retry
        let task = session.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            guard error == nil, let http = response as? HTTPURLResponse else { outcome = .retry; return }
            switch http.statusCode {
            case 200..<300: outcome = .sent
            case 402:
                Trel.debugLog("plan limit reached (402); sending disabled for this process")
                outcome = .disabled
            case 429, 500...: outcome = .retry
            case 401, 403:
                Trel.debugLog("rejected (\(http.statusCode)): check apiKey")
                outcome = .drop
            default: outcome = .drop
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return outcome
    }
}

/// Minimal gzip via zlib (no third-party dependency).
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var out = Data(capacity: data.count / 2 + 64)
        let chunk = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var input = [UInt8](data)
        return input.withUnsafeMutableBufferPointer { inPtr -> Data? in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)
            repeat {
                let produced: Int? = buffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { return nil }
                    return chunk - Int(stream.avail_out)
                }
                guard let n = produced else { return nil }
                out.append(buffer, count: n)
            } while status != Z_STREAM_END
            return out
        }
    }
}
