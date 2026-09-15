import Foundation

/// Main-thread watchdog: pings the main run loop every 0.5 s; if a ping is not serviced within
/// `timeout` the app is hanging. Reports one `AppHang` (mechanism `app_hang`, severity ERROR, the
/// app is still alive) per stall with the main thread's stack captured through KSCrash.
final class AppHangWatchdog {
    private let trel: Trel
    private let timeout: TimeInterval
    private let thread: Thread
    private var lastPong = Date()
    private let lock = NSLock()
    private var reported = false
    private var running = true

    init(trel: Trel, timeout: TimeInterval) {
        self.trel = trel
        self.timeout = max(0.5, timeout)
        thread = Thread()
        thread.name = "to.trel.app-hang-watchdog"
        thread.qualityOfService = .utility
    }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.name = "to.trel.app-hang-watchdog"
        t.qualityOfService = .utility
        t.start()
    }

    func stop() { running = false }

    private func loop() {
        while running {
            lock.lock(); lastPong = Date(); lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock(); self.lastPong = Date(); self.lock.unlock()
            }
            Thread.sleep(forTimeInterval: 0.5)
            lock.lock(); let stalled = Date().timeIntervalSince(lastPong); lock.unlock()
            if stalled >= timeout {
                if !reported {
                    reported = true
                    report(stalled)
                }
            } else {
                reported = false
            }
        }
    }

    private func report(_ stalled: TimeInterval) {
        guard !trel.isBackgrounded else { return }
        let message = String(format: "Main thread unresponsive for %.1fs", stalled)
        var attrs = trel.baseAttributes(nil)
        attrs[Attr.threadName] = "main"
        let stack = trel.crashReporter?.mainThreadStack(header: "AppHang: \(message)") ?? "AppHang: \(message)"
        let event = TrelEvent(type: "AppHang", message: message, stacktrace: stack, mechanism: "app_hang", attributes: attrs)
        trel.enqueue(event: event, fatal: false, sync: false, at: Date())
        trel.session.markErrored(queue: trel.queue)
    }
}
