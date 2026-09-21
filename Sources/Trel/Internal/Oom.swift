import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Foreground jetsam: previous launch was in the foreground, did not crash, and was not backgrounded.
enum Oom {
    private static let foregroundKey = "to.trel.session.was_foreground"
    private static let cleanKey = "to.trel.session.clean_exit"

    static func notePrevious(trel: Trel, crashed: Bool, previousSessionId: String?) {
        let defaults = UserDefaults.standard
        let wasForeground = defaults.bool(forKey: foregroundKey)
        let clean = defaults.bool(forKey: cleanKey)
        if let previous = previousSessionId, wasForeground, !clean, !crashed {
            var attrs = trel.baseAttributes(nil)
            attrs.removeValue(forKey: Attr.breadcrumbs)
            attrs["trel.exit.reason"] = "foreground_kill"
            attrs[Attr.sessionId] = previous
            let event = TrelEvent(
                type: "OutOfMemory",
                message: "App was killed in the foreground without a crash report",
                stacktrace: "OutOfMemory: foreground kill",
                mechanism: "oom",
                attributes: attrs
            )
            trel.enqueue(event: event, fatal: true, sync: false, at: Date())
        }
        defaults.set(true, forKey: foregroundKey)
        defaults.set(false, forKey: cleanKey)
        #if canImport(MetricKit)
        if #available(iOS 14.0, *) { MXMetricManager.shared.add(OomSubscriber(trel: trel)) }
        #endif
    }

    static func markClean(_ clean: Bool) {
        UserDefaults.standard.set(clean, forKey: cleanKey)
    }

    static func markForeground(_ foreground: Bool) {
        UserDefaults.standard.set(foreground, forKey: foregroundKey)
    }
}

#if canImport(MetricKit)
@available(iOS 14.0, *)
private final class OomSubscriber: NSObject, MXMetricManagerSubscriber {
    let trel: Trel
    init(trel: Trel) { self.trel = trel }
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let exits = payload.applicationExitMetrics?.foregroundExitData.cumulativeMemoryResourceLimitExitCount ?? 0
            if exits > 0 {
                var attrs = trel.baseAttributes(nil)
                attrs["trel.exit.reason"] = "metrickit_memory"
                let event = TrelEvent(type: "OutOfMemory", message: "MetricKit memory-limit exit", stacktrace: "OutOfMemory: MetricKit", mechanism: "oom", attributes: attrs)
                trel.enqueue(event: event, fatal: true, sync: false, at: payload.timeStampEnd)
            }
        }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {}
}
#endif
