import Foundation

enum Replay {
    static var paused = false
    private static var started = false

    static func start(_ trel: Trel) {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .utility).async {
            while started {
                Thread.sleep(forTimeInterval: 1)
                if paused || !trel.lifecycle.isForeground { continue }
                if let bytes = Screenshot.capture(maskText: trel.options.maskAllText) {
                    trel.attachments.enqueue(type: "replay", body: bytes, eventId: nil, traceId: nil, sessionId: trel.session.id, fatal: false)
                }
            }
        }
    }
}
