import Foundation

/// Trel for iOS: crashes, app hangs, handled errors, breadcrumbs, sessions, network spans and logs.
///
/// ```swift
/// Trel.start(TrelOptions(apiKey: "trel_sk_…", environment: "production"))
/// ```
///
/// Everything is written to a disk queue first and shipped in the background, so a crash on the
/// very first frame still arrives on the next launch. All methods are thread-safe and no-ops before
/// `start`.
public final class Trel {
    static let sdkName = "trel-ios"
    static let sdkVersion = "0.1.0"

    private static let lock = NSLock()
    private static var current: Trel?

    /// The running instance, if `start` has been called.
    public static var shared: Trel? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public static var isStarted: Bool { shared != nil }

    let options: TrelOptions
    let resource: Resource
    let scope: Scope
    let queue: Queue
    let transport: Transport
    let session: Session
    let lifecycle: Lifecycle
    private(set) var crashReporter: CrashReporter?
    private var hangWatchdog: AppHangWatchdog?

    var isStarted: Bool { Trel.shared === self }
    var isBackgrounded: Bool { !lifecycle.isForeground }

    // MARK: - Lifecycle

    @discardableResult
    public static func start(_ options: TrelOptions) -> Trel {
        lock.lock()
        if let existing = current {
            lock.unlock()
            debugLog("start called twice; ignoring")
            return existing
        }
        let instance = Trel(options: options)
        current = instance
        lock.unlock()
        instance.boot()
        return instance
    }

    private init(options: TrelOptions) {
        self.options = options
        resource = Resource(options: options)
        scope = Scope(maxBreadcrumbs: options.maxBreadcrumbs)
        queue = Queue(resource: resource)
        session = Session()
        transport = Transport(options: options, queue: queue, resource: resource)
        lifecycle = Lifecycle(trel: nil)
        lifecycle.attach(self)
    }

    private func boot() {
        var crashedHint = false
        if options.enableCrashReporting {
            let reporter = CrashReporter(trel: self)
            reporter.install()
            crashReporter = reporter
            // Previous-run reports first, so the `crashed` session signal has something to point at.
            crashedHint = reporter.drainPendingReports() || reporter.crashedLastLaunch
            reporter.setContext(session.id, forKey: Attr.sessionId)
        }
        session.reportPreviousRun(queue: queue, crashedHint: crashedHint)
        session.start(queue: queue)

        lifecycle.install(viewControllerBreadcrumbs: options.enableViewControllerBreadcrumbs)
        if options.enableAppHangs {
            hangWatchdog = AppHangWatchdog(trel: self, timeout: options.appHangTimeout)
            hangWatchdog?.start()
        }
        if options.enableNetwork { NetworkInstrumentation.install(trel: self) }
        transport.start()
        Trel.debugLog("started v\(Trel.sdkVersion) release=\(resource.release) env=\(options.environment)")
    }

    // MARK: - Capture

    /// Reports a handled error. Returns immediately; delivery is asynchronous.
    public static func capture(_ error: Error, attributes: [String: Any]? = nil) {
        shared?.capture(error, attributes: attributes)
    }

    public func capture(_ error: Error, attributes: [String: Any]? = nil) {
        let ns = error as NSError
        let type = String(describing: Swift.type(of: error)) == "NSError" ? ns.domain : String(reflecting: Swift.type(of: error))
        let message = (error as? LocalizedError)?.errorDescription ?? ns.localizedDescription
        var attrs = baseAttributes(attributes)
        attrs[Attr.threadName] = Thread.current.name?.isEmpty == false ? Thread.current.name! : (Thread.isMainThread ? "main" : "background")
        attrs["error.domain"] = ns.domain
        attrs["error.code"] = ns.code
        let stack = Trel.appleStack(Thread.callStackSymbols.dropFirst(2), header: "\(type): \(message)")
        let event = TrelEvent(type: type, message: message, stacktrace: stack, mechanism: "handled", attributes: attrs)
        enqueue(event: event, fatal: false, sync: false, at: Date())
        session.markErrored(queue: queue)
    }

    /// Reports a message. `.error`/`.fatal` become issues; lower levels become log records.
    public static func captureMessage(_ message: String, level: TrelLevel = .info, attributes: [String: Any]? = nil) {
        shared?.captureMessage(message, level: level, attributes: attributes)
    }

    public func captureMessage(_ message: String, level: TrelLevel = .info, attributes: [String: Any]? = nil) {
        if level >= .error {
            let attrs = baseAttributes(attributes)
            let stack = Trel.appleStack(Thread.callStackSymbols.dropFirst(2), header: "Message: \(message)")
            let event = TrelEvent(type: "Message", message: message, stacktrace: stack, mechanism: "handled", attributes: attrs)
            enqueue(event: event, fatal: false, sync: false, at: Date())
        } else {
            log(level, message, attributes: attributes)
        }
    }

    /// Ships a log record (billed as an event). Use `addBreadcrumb` for free context instead.
    public static func log(_ level: TrelLevel, _ message: String, attributes: [String: Any]? = nil) {
        shared?.log(level, message, attributes: attributes)
    }

    public func log(_ level: TrelLevel, _ message: String, attributes: [String: Any]? = nil) {
        guard level >= options.minLogLevel else { return }
        var attrs = attributes ?? [:]
        scope.user.apply(to: &attrs)
        attrs[Attr.sessionId] = session.id
        queue.enqueueLog(Otlp.logRecord(Date(), level: level, body: message, attrs: attrs))
    }

    public static func addBreadcrumb(_ breadcrumb: Breadcrumb) { shared?.addBreadcrumb(breadcrumb) }

    public static func addBreadcrumb(_ message: String, category: String = "default", data: [String: Any]? = nil) {
        shared?.addBreadcrumb(Breadcrumb(message: message, category: category, data: data))
    }

    public func addBreadcrumb(_ breadcrumb: Breadcrumb) {
        scope.add(breadcrumb)
        crashReporter?.setContext(Otlp.breadcrumbsJson(scope.breadcrumbs()), forKey: Attr.breadcrumbs)
        if options.breadcrumbsAsLogs {
            var attrs: [String: Any] = ["breadcrumb.category": breadcrumb.category, Attr.sessionId: session.id]
            breadcrumb.data?.forEach { attrs["breadcrumb.\($0.key)"] = $0.value }
            queue.enqueueLog(Otlp.logRecord(breadcrumb.timestamp, level: breadcrumb.level, body: breadcrumb.message, attrs: attrs))
        }
    }

    /// Identifies the current user; drives "users affected". Pass `nil` id to clear.
    public static func setUser(id: String?, email: String? = nil, name: String? = nil) {
        shared?.setUser(id: id, email: email, name: name)
    }

    public func setUser(id: String?, email: String? = nil, name: String? = nil) {
        scope.setUser(id: id, email: email, name: name)
        crashReporter?.setContext(id, forKey: Attr.userId)
        crashReporter?.setContext(email, forKey: Attr.userEmail)
        crashReporter?.setContext(name, forKey: Attr.userName)
    }

    /// Free-form tag attached to every exception as `trel.tag.<key>` (max 20).
    public static func setTag(_ key: String, _ value: String?) { shared?.setTag(key, value) }

    public func setTag(_ key: String, _ value: String?) {
        scope.setTag(key, value)
        crashReporter?.setContext(value, forKey: Attr.tagPrefix + key)
    }

    /// Blocks (up to `timeout`) until the queue has been sent.
    public static func flush(timeout: TimeInterval = 3) { shared?.flush(timeout: timeout) }

    public func flush(timeout: TimeInterval = 3) { transport.flushBlocking(timeout: timeout) }

    /// Current session id (per process launch).
    public static var sessionId: String? { shared?.session.id }

    // MARK: - HTTP spans for custom clients

    /// Starts an HTTP CLIENT span for a request you make outside `URLSession` (or with
    /// `enableNetwork` off). Add `traceparent` as a request header, then call `finish`.
    public static func startHttpSpan(method: String, url: URL) -> HttpSpan? {
        shared.map { HttpSpan(trel: $0, method: method, url: url) }
    }

    public final class HttpSpan {
        private let trel: Trel
        private let method: String
        private let url: String
        private let traceId = Ids.traceId()
        private let spanId = Ids.spanId()
        private let start = Date()
        private var finished = false

        init(trel: Trel, method: String, url: URL) {
            self.trel = trel
            self.method = method
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.query = nil
            self.url = comps?.string ?? url.absoluteString
        }

        public var traceparent: String { "00-\(traceId)-\(spanId)-01" }

        public func finish(statusCode: Int = 0, error: Error? = nil) {
            guard !finished else { return }
            finished = true
            let u = URL(string: url)
            var attrs: [String: Any] = [
                Attr.httpMethod: method,
                Attr.urlFull: url,
                Attr.serverAddress: u?.host ?? "",
                Attr.sessionId: trel.session.id,
            ]
            if statusCode > 0 { attrs[Attr.httpStatus] = statusCode }
            if let error = error as NSError? { attrs["error.type"] = error.domain }
            trel.queue.enqueueSpan(Otlp.span(
                name: "\(method) \(u?.path.isEmpty == false ? u!.path : "/")",
                kind: Otlp.spanKindClient,
                traceId: traceId,
                spanId: spanId,
                parentSpanId: nil,
                start: start,
                end: Date(),
                ok: error == nil && statusCode < 500,
                attrs: attrs
            ))
        }
    }

    // MARK: - Internal

    func baseAttributes(_ extra: [String: Any]?) -> [String: Any] {
        var attrs = extra ?? [:]
        scope.user.apply(to: &attrs)
        for (k, v) in scope.tags { attrs[Attr.tagPrefix + k] = v }
        attrs[Attr.sessionId] = session.id
        attrs[Attr.appState] = lifecycle.isForeground ? "foreground" : "background"
        attrs[Attr.appUptimeMs] = resource.uptimeMs
        attrs[Attr.breadcrumbs] = Otlp.breadcrumbsJson(scope.breadcrumbs())
        resource.deviceState(into: &attrs)
        return attrs
    }

    /// Applies `beforeSend` and writes the exception record.
    func enqueue(event: TrelEvent, fatal: Bool, sync: Bool, at date: Date) {
        var finalEvent = event
        if let hook = options.beforeSend {
            guard let e = hook(event) else { return }
            finalEvent = e
        }
        let record = Otlp.exceptionRecord(date, event: finalEvent, fatal: fatal)
        if sync { queue.writeLogsNow([record]) } else { queue.enqueueLog(record) }
    }

    /// `Thread.callStackSymbols` lines are already Apple-formatted (`N  Image  0xADDR symbol + off`).
    static func appleStack<S: Sequence>(_ symbols: S, header: String) -> String where S.Element == String {
        ([header] + symbols.map { $0.replacingOccurrences(of: "\\s+", with: "   ", options: .regularExpression) }).joined(separator: "\n")
    }

    static func debugLog(_ message: String) {
        guard shared?.options.debug == true else { return }
        NSLog("[Trel] %@", message)
    }
}
