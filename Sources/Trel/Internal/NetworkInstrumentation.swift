import Foundation

/// `URLSession` instrumentation: swizzles `URLSessionTask.resume()` to start an HTTP CLIENT span
/// and observes the task's `state` until completion to finish it with status / error. The Trel
/// ingest host is ignored. `traceparent` is injected for the request-based `dataTask` factories.
final class NetworkInstrumentation: NSObject {
    private static var installed = false
    private static weak var trel: Trel?
    private static let lock = NSLock()
    private static var spans: [ObjectIdentifier: (traceId: String, spanId: String, start: Date, method: String, url: String)] = [:]
    private static var observers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    static func install(trel: Trel) {
        guard !installed else { return }
        installed = true
        self.trel = trel
        swizzleResume()
        swizzleDataTaskFactories()
    }

    // MARK: resume → span start

    private static func swizzleResume() {
        // `resume` is implemented on a private subclass; swizzle the class of a real task instance.
        let session = URLSession(configuration: .ephemeral)
        let probe = session.dataTask(with: URL(string: "https://trel.to/probe")!)
        var cls: AnyClass? = object_getClass(probe)
        var swizzledOnce = false
        while let c = cls, !swizzledOnce {
            if let m = class_getInstanceMethod(c, #selector(URLSessionTask.resume)),
               class_getInstanceMethod(class_getSuperclass(c), #selector(URLSessionTask.resume)) != m || c == URLSessionTask.self {
                let original = method_getImplementation(m)
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                let originalFn = unsafeBitCast(original, to: Fn.self)
                let block: @convention(block) (AnyObject) -> Void = { obj in
                    if let task = obj as? URLSessionTask { NetworkInstrumentation.taskWillResume(task) }
                    originalFn(obj, #selector(URLSessionTask.resume))
                }
                method_setImplementation(m, imp_implementationWithBlock(block))
                swizzledOnce = true
            }
            cls = class_getSuperclass(c)
        }
        probe.cancel()
        session.invalidateAndCancel()
    }

    private static func taskWillResume(_ task: URLSessionTask) {
        guard let trel = trel, trel.isStarted, let request = task.originalRequest ?? task.currentRequest, let url = request.url else { return }
        let host = url.host ?? ""
        if host.hasSuffix("trel.to") || host == trel.options.endpoint.host { return }
        let key = ObjectIdentifier(task)
        lock.lock()
        let alreadyTracked = spans[key] != nil
        lock.unlock()
        if alreadyTracked { return }

        let traceId = request.value(forHTTPHeaderField: "traceparent").flatMap(NetworkInstrumentation.traceIdFromTraceparent) ?? Ids.traceId()
        let spanId = request.value(forHTTPHeaderField: "traceparent").flatMap(NetworkInstrumentation.spanIdFromTraceparent) ?? Ids.spanId()
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        let cleanUrl = comps?.string ?? url.absoluteString
        let entry = (traceId: traceId, spanId: spanId, start: Date(), method: request.httpMethod ?? "GET", url: cleanUrl)

        let observation = task.observe(\.state, options: [.new]) { task, _ in
            guard task.state == .completed || task.state == .canceling else { return }
            NetworkInstrumentation.taskDidFinish(task)
        }
        lock.lock()
        spans[key] = entry
        observers[key] = observation
        lock.unlock()
    }

    private static func taskDidFinish(_ task: URLSessionTask) {
        let key = ObjectIdentifier(task)
        lock.lock()
        let entry = spans.removeValue(forKey: key)
        let observation = observers.removeValue(forKey: key)
        lock.unlock()
        observation?.invalidate()
        guard let e = entry, let trel = trel else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let error = task.error
        let end = Date()
        let host = URL(string: e.url)?.host ?? ""
        let path = URL(string: e.url)?.path ?? "/"
        var attrs: [String: Any] = [
            Attr.httpMethod: e.method,
            Attr.urlFull: e.url,
            Attr.serverAddress: host,
            Attr.sessionId: trel.session.id,
        ]
        if status > 0 { attrs[Attr.httpStatus] = status }
        if let error = error as NSError? { attrs["error.type"] = error.domain + "." + String(error.code) }
        trel.queue.enqueueSpan(Otlp.span(
            name: "\(e.method) \(path.isEmpty ? "/" : path)",
            kind: Otlp.spanKindClient,
            traceId: e.traceId,
            spanId: e.spanId,
            parentSpanId: nil,
            start: e.start,
            end: end,
            ok: error == nil && status < 500,
            attrs: attrs
        ))
        if trel.options.enableNetworkBreadcrumbs {
            let outcome = status > 0 ? String(status) : (error.map { ($0 as NSError).domain } ?? "")
            let level: TrelLevel = error != nil || status >= 500 ? .error : status >= 400 ? .warn : .info
            trel.addBreadcrumb(Breadcrumb(
                message: "\(e.method) \(e.url) \(outcome)".trimmingCharacters(in: .whitespaces),
                category: "http",
                level: level,
                data: ["method": e.method, "url": e.url, "status": status, "duration_ms": Int(end.timeIntervalSince(e.start) * 1000)]
            ))
        }
    }

    // MARK: traceparent injection for request-based factories

    private static func swizzleDataTaskFactories() {
        let cls: AnyClass = URLSession.self
        let pairs: [(Selector, Selector)] = [
            (#selector(URLSession.dataTask(with:) as (URLSession) -> (URLRequest) -> URLSessionDataTask), #selector(URLSession.trel_dataTask(with:))),
            (#selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask), #selector(URLSession.trel_dataTask(with:completionHandler:))),
        ]
        for (original, swizzled) in pairs {
            guard let om = class_getInstanceMethod(cls, original), let sm = class_getInstanceMethod(cls, swizzled) else { continue }
            method_exchangeImplementations(om, sm)
        }
    }

    static func inject(_ request: URLRequest) -> URLRequest {
        guard let trel = trel, trel.isStarted, let host = request.url?.host, !host.hasSuffix("trel.to"), host != trel.options.endpoint.host else { return request }
        if request.value(forHTTPHeaderField: "traceparent") != nil { return request }
        var r = request
        r.setValue("00-\(Ids.traceId())-\(Ids.spanId())-01", forHTTPHeaderField: "traceparent")
        return r
    }

    private static func traceIdFromTraceparent(_ tp: String) -> String? {
        let parts = tp.split(separator: "-")
        return parts.count == 4 && parts[1].count == 32 ? String(parts[1]) : nil
    }

    private static func spanIdFromTraceparent(_ tp: String) -> String? {
        let parts = tp.split(separator: "-")
        return parts.count == 4 && parts[2].count == 16 ? String(parts[2]) : nil
    }
}

extension URLSession {
    @objc fileprivate func trel_dataTask(with request: URLRequest) -> URLSessionDataTask {
        trel_dataTask(with: NetworkInstrumentation.inject(request)) // exchanged: calls the original
    }

    @objc fileprivate func trel_dataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        trel_dataTask(with: NetworkInstrumentation.inject(request), completionHandler: completionHandler)
    }
}
