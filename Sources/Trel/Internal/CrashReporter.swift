import Foundation
import KSCrashRecording

/// KSCrash-backed crash capture. Mach exceptions, signals, C++ exceptions, NSExceptions and Swift
/// runtime traps are written by KSCrash at crash time; on the next launch we convert each report
/// into an exception record (Apple-format stack + `trel.debug_meta` binary images) and delete it.
///
/// Live context (user, tags, session, breadcrumbs) is pushed into KSCrash's per-key user info so
/// it is embedded in the report even though our process is gone by the time we read it.
final class CrashReporter {
    private let trel: Trel
    private(set) var installed = false
    private(set) var crashedLastLaunch = false
    private var mainMachThread: thread_t = 0

    init(trel: Trel) {
        self.trel = trel
    }

    func install() {
        let config = KSCrashConfiguration()
        config.monitors = [.machException, .signal, .cppException, .nsException, .userReported, .system, .applicationState, .userInfo]
        config.enableSwiftAsyncStackTraces = true
        config.enableCompactBinaryImages = false
        config.reportStoreConfiguration.maxReportCount = 10
        config.reportStoreConfiguration.appName = trel.resource.bundleId
        do {
            try KSCrash.shared.install(with: config)
            installed = true
            crashedLastLaunch = KSCrash.shared.crashedLastLaunch
            if Thread.isMainThread {
                mainMachThread = pthread_mach_thread_np(pthread_self())
            } else {
                DispatchQueue.main.async { [weak self] in self?.mainMachThread = pthread_mach_thread_np(pthread_self()) }
            }
        } catch {
            Trel.debugLog("KSCrash install failed: \(error)")
        }
    }

    // MARK: - Live context

    func setContext(_ value: String?, forKey key: String) {
        guard installed else { return }
        if let value = value { KSCrash.shared.setUserInfo(value, forKey: key) } else { KSCrash.shared.removeUserInfoValue(forKey: key) }
    }

    // MARK: - Pending reports → events

    /// Converts every stored report into an exception record. Returns true when any fatal report was found.
    func drainPendingReports() -> Bool {
        guard installed, let store = KSCrash.shared.reportStore else { return false }
        var sawFatal = false
        let jsFatalReported = UserDefaults.standard.bool(forKey: Trel.jsFatalKey)
        UserDefaults.standard.set(false, forKey: Trel.jsFatalKey)
        for id in store.reportIDs {
            let reportId = id.int64Value
            defer { store.deleteReport(with: reportId) }
            guard let report = store.report(for: reportId) else { continue }
            guard let (event, date, fatal) = convert(report.value) else { continue }
            if fatal { sawFatal = true }
            // A fatal JS error already reported by the React Native SDK re-surfaces as RCTFatalException.
            if jsFatalReported && (event.type.hasPrefix("RCTFatal") || event.type.hasPrefix("RCTJavaScript")) { continue }
            trel.enqueue(event: event, fatal: fatal, sync: false, at: date)
        }
        return sawFatal
    }

    /// Report → (event, timestamp, fatal). `AppHang` user reports are non-fatal.
    func convert(_ report: [String: Any]) -> (TrelEvent, Date, Bool)? {
        guard let crash = report["crash"] as? [String: Any] else { return nil }
        let error = crash["error"] as? [String: Any] ?? [:]
        let errType = error["type"] as? String ?? "unknown"
        let reportInfo = report["report"] as? [String: Any] ?? [:]
        let userInfo = report["user"] as? [String: Any] ?? [:]

        var type = "Crash"
        var message = error["reason"] as? String ?? crash["diagnosis"] as? String ?? ""
        var mechanism = "crash"
        switch errType {
        case "nsexception":
            let ns = error["nsexception"] as? [String: Any] ?? [:]
            type = ns["name"] as? String ?? "NSException"
            message = ns["reason"] as? String ?? message
        case "mach":
            let mach = error["mach"] as? [String: Any] ?? [:]
            let sig = error["signal"] as? [String: Any] ?? [:]
            type = mach["exception_name"] as? String ?? "EXC_CRASH"
            let sigName = sig["name"] as? String
            let addr = (error["address"] as? NSNumber).map { String(format: "0x%llx", $0.uint64Value) }
            if message.isEmpty {
                message = [type, sigName.map { "(\($0))" }, addr.map { "at \($0)" }].compactMap { $0 }.joined(separator: " ")
            }
        case "signal":
            let sig = error["signal"] as? [String: Any] ?? [:]
            type = sig["name"] as? String ?? "SIGNAL"
            if message.isEmpty { message = "Signal \(type)" }
        case "cpp_exception":
            let cpp = error["cpp_exception"] as? [String: Any] ?? [:]
            type = cpp["name"] as? String ?? "std::exception"
        case "user":
            let user = error["user_reported"] as? [String: Any] ?? [:]
            type = user["name"] as? String ?? "UserReported"
            if type == "AppHang" { mechanism = "app_hang" }
        default:
            break
        }
        if message.isEmpty { message = type }

        let threads = crash["threads"] as? [[String: Any]] ?? []
        let crashed = threads.first { ($0["crashed"] as? Bool) == true } ?? threads.first { ($0["index"] as? Int) == 0 } ?? threads.first
        let stack = CrashReporter.appleStack(thread: crashed, header: "\(type): \(message)")

        var attrs = trel.baseAttributes(nil)
        // Context captured by KSCrash at crash time beats whatever this launch knows.
        attrs.removeValue(forKey: Attr.breadcrumbs)
        for (k, v) in userInfo where k.hasPrefix("trel.") || k.hasPrefix("enduser.") || k.hasPrefix("session.") {
            attrs[k] = v
        }
        if attrs[Attr.breadcrumbs] == nil { attrs[Attr.breadcrumbs] = "[]" }
        if let name = crashed?["name"] as? String { attrs[Attr.threadName] = name } else if let q = crashed?["dispatch_queue"] as? String { attrs[Attr.threadName] = q }
        if let images = report["binary_images"] as? [[String: Any]] { attrs[Attr.debugMeta] = CrashReporter.debugMeta(images) }
        if let diagnosis = crash["diagnosis"] as? String { attrs["trel.diagnosis"] = diagnosis }
        attrs[Attr.appState] = "foreground"

        let date = CrashReporter.parseTimestamp(reportInfo["timestamp"]) ?? Date()
        let event = TrelEvent(type: type, message: message, stacktrace: stack, mechanism: mechanism, attributes: attrs)
        return (event, date, mechanism != "app_hang")
    }

    /// Apple crash-log frame format: `N   Image   0xADDR symbol + offset`, which ingest parses natively.
    static func appleStack(thread: [String: Any]?, header: String) -> String {
        var lines = [header]
        let contents = (thread?["backtrace"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
        for (i, frame) in contents.prefix(200).enumerated() {
            let addr = (frame["instruction_addr"] as? NSNumber)?.uint64Value ?? 0
            let objectAddr = (frame["object_addr"] as? NSNumber)?.uint64Value ?? 0
            let symbolAddr = (frame["symbol_addr"] as? NSNumber)?.uint64Value ?? 0
            let image = ((frame["object_name"] as? String) ?? "???").split(separator: "/").last.map(String.init) ?? "???"
            let symbol = frame["symbol_name"] as? String
            let addrHex = String(format: "0x%016llx", addr)
            let tail: String
            if let symbol = symbol, !symbol.isEmpty, symbol != "<redacted>" {
                tail = "\(symbol) + \(addr >= symbolAddr ? addr - symbolAddr : 0)"
            } else {
                tail = String(format: "0x%llx + %llu", objectAddr, addr >= objectAddr ? addr - objectAddr : 0)
            }
            lines.append("\(i)   \(image.replacingOccurrences(of: " ", with: "_"))   \(addrHex) \(tail)")
        }
        return lines.joined(separator: "\n")
    }

    static func debugMeta(_ images: [[String: Any]]) -> String {
        let list: [[String: Any]] = images.prefix(500).compactMap { img in
            guard let name = img["name"] as? String else { return nil }
            var o: [String: Any] = ["name": name.split(separator: "/").last.map(String.init) ?? name]
            if let uuid = img["uuid"] as? String { o["uuid"] = uuid }
            if let addr = (img["image_addr"] as? NSNumber)?.uint64Value { o["addr"] = String(format: "0x%llx", addr) }
            if let size = (img["image_size"] as? NSNumber)?.uint64Value { o["size"] = size }
            return o
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["images": list]), let s = String(data: data, encoding: .utf8) else { return "{\"images\":[]}" }
        return s
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseTimestamp(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            return isoFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        if let n = raw as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        return nil
    }

    // MARK: - Live main-thread stack (app hangs)

    /// Captures and symbolicates the main thread from another thread. Empty when unavailable.
    func mainThreadStack(header: String) -> String {
        guard installed, mainMachThread != 0 else { return header }
        var addresses = [UInt](repeating: 0, count: 128)
        let count = addresses.withUnsafeMutableBufferPointer { buf -> Int32 in
            KSCrash.shared.captureBacktrace(fromMachThread: mainMachThread, addresses: buf.baseAddress!, count: Int32(buf.count))
        }
        var lines = [header]
        for i in 0..<Int(max(0, count)) {
            let addr = addresses[i]
            var info = SymbolInformation()
            let ok = KSCrash.shared.symbolicateAddress(addr, result: &info)
            let image = ok && info.imageName != nil ? (String(cString: info.imageName!).split(separator: "/").last.map(String.init) ?? "???") : "???"
            let addrHex = String(format: "0x%016lx", addr)
            let tail: String
            if ok, let sym = info.symbolName {
                tail = "\(String(cString: sym)) + \(addr >= info.symbolAddress ? addr - info.symbolAddress : 0)"
            } else if ok {
                tail = String(format: "0x%lx + %lu", info.imageAddress, addr >= info.imageAddress ? addr - info.imageAddress : 0)
            } else {
                tail = "0x0 + 0"
            }
            lines.append("\(i)   \(image.replacingOccurrences(of: " ", with: "_"))   \(addrHex) \(tail)")
        }
        return lines.joined(separator: "\n")
    }
}
