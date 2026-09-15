import Foundation

/// One session per process launch. `started` on init; `errored` once on the first handled error;
/// `crashed` on the next launch when the previous run left a dirty marker or a pending crash report.
final class Session {
    let id = UUID().uuidString.lowercased()
    private let defaults = UserDefaults.standard
    private var errored = false
    private let lock = NSLock()

    private static let keySession = "to.trel.session.id"
    private static let keyPrevious = "to.trel.session.previous"
    private static let keyCrashed = "to.trel.session.crashed"

    func reportPreviousRun(queue: Queue, crashedHint: Bool) {
        let previousId = defaults.string(forKey: Session.keySession)
        let crashed = defaults.bool(forKey: Session.keyCrashed) || crashedHint || queue.hasCrashEnvelope()
        if let previousId = previousId, crashed {
            queue.enqueueLog(Otlp.sessionRecord(id: previousId, status: "crashed", previousId: nil, date: Date()))
        }
        defaults.set(id, forKey: Session.keySession)
        defaults.set(false, forKey: Session.keyCrashed)
    }

    func start(queue: Queue) {
        queue.enqueueLog(Otlp.sessionRecord(id: id, status: "started", previousId: defaults.string(forKey: Session.keyPrevious), date: Date()))
        defaults.set(id, forKey: Session.keyPrevious)
    }

    func markErrored(queue: Queue) {
        lock.lock()
        let first = !errored
        errored = true
        lock.unlock()
        if first { queue.enqueueLog(Otlp.sessionRecord(id: id, status: "errored", previousId: nil, date: Date())) }
    }

    func markCrashed() {
        defaults.set(true, forKey: Session.keyCrashed)
        defaults.synchronize()
    }
}
