import Foundation

/// OTLP/JSON builders. Records are `[String: Any]` so the disk queue can store them verbatim.
enum Otlp {
    static let spanKindInternal = 1
    static let spanKindClient = 3
    private static let maxString = 64 * 1024

    static func anyValue(_ v: Any?) -> [String: Any]? {
        guard let v = v else { return nil }
        switch v {
        case let b as Bool: return ["boolValue": b]
        case let i as Int: return ["intValue": String(i)]
        case let i as Int64: return ["intValue": String(i)]
        case let i as UInt: return ["intValue": String(i)]
        case let d as Double: return ["doubleValue": d]
        case let f as Float: return ["doubleValue": Double(f)]
        case let s as String: return ["stringValue": String(s.prefix(maxString))]
        case let dict as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: sanitize(dict)), let s = String(data: data, encoding: .utf8) {
                return ["stringValue": String(s.prefix(maxString))]
            }
            return nil
        case let arr as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: sanitize(arr)), let s = String(data: data, encoding: .utf8) {
                return ["stringValue": String(s.prefix(maxString))]
            }
            return nil
        case let n as NSNumber: return ["doubleValue": n.doubleValue]
        default: return ["stringValue": String(describing: v).prefix(maxString).description]
        }
    }

    /// JSONSerialization refuses Date / URL / custom types; stringify them.
    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues { sanitize($0) }
        case let arr as [Any]: return arr.map { sanitize($0) }
        case is String, is Bool, is Int, is Double, is Float, is Int64, is NSNumber, is NSNull: return value
        case let date as Date: return Int(date.timeIntervalSince1970 * 1000)
        case let url as URL: return url.absoluteString
        default: return String(describing: value)
        }
    }

    static func attributes(_ map: [String: Any]) -> [[String: Any]] {
        map.compactMap { key, value in
            guard let v = anyValue(value) else { return nil }
            return ["key": key, "value": v]
        }
    }

    private static func nanos(_ date: Date) -> String {
        String(UInt64(date.timeIntervalSince1970 * 1_000_000_000))
    }

    static func logRecord(_ date: Date, level: TrelLevel, body: String, attrs: [String: Any]) -> [String: Any] {
        [
            "timeUnixNano": nanos(date),
            "severityNumber": level.rawValue,
            "severityText": level.label,
            "body": ["stringValue": String(body.prefix(maxString))],
            "attributes": attributes(attrs),
        ]
    }

    static func exceptionRecord(_ date: Date, event: TrelEvent, fatal: Bool) -> [String: Any] {
        var attrs = event.attributes
        attrs[Attr.exceptionType] = event.type
        attrs[Attr.exceptionMessage] = event.message
        attrs[Attr.exceptionStacktrace] = event.stacktrace
        attrs[Attr.exceptionEscaped] = fatal
        attrs[Attr.mechanism] = event.mechanism
        return logRecord(date, level: fatal ? .fatal : .error, body: event.message, attrs: attrs)
    }

    static func sessionRecord(id: String, status: String, previousId: String?, date: Date) -> [String: Any] {
        var attrs: [String: Any] = [Attr.signal: "session", Attr.sessionId: id, Attr.sessionStatus: status]
        if let p = previousId { attrs[Attr.sessionPreviousId] = p }
        return logRecord(date, level: .info, body: "session", attrs: attrs)
    }

    static func span(name: String, kind: Int, traceId: String, spanId: String, parentSpanId: String?, start: Date, end: Date, ok: Bool, attrs: [String: Any]) -> [String: Any] {
        var span: [String: Any] = [
            "traceId": traceId,
            "spanId": spanId,
            "name": String(name.prefix(256)),
            "kind": kind,
            "startTimeUnixNano": nanos(start),
            "endTimeUnixNano": nanos(max(start, end)),
            "attributes": attributes(attrs),
            "status": ["code": ok ? 1 : 2],
        ]
        if let p = parentSpanId { span["parentSpanId"] = p }
        return span
    }

    static func breadcrumbsJson(_ list: [Breadcrumb]) -> String {
        let arr: [[String: Any]] = list.map { b in
            var o: [String: Any] = [
                "ts": Int(b.timestamp.timeIntervalSince1970 * 1000),
                "category": b.category,
                "message": String(b.message.prefix(1000)),
                "level": b.level.breadcrumbLabel,
            ]
            if let d = b.data { o["data"] = sanitize(d) }
            return o
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private static func scope() -> [String: Any] { ["name": Trel.sdkName, "version": Trel.sdkVersion] }

    static func logsBody(resource: [String: Any], records: [[String: Any]]) -> [String: Any] {
        ["resourceLogs": [[
            "resource": ["attributes": attributes(resource)],
            "scopeLogs": [["scope": scope(), "logRecords": records]],
        ]]]
    }

    static func tracesBody(resource: [String: Any], spans: [[String: Any]]) -> [String: Any] {
        ["resourceSpans": [[
            "resource": ["attributes": attributes(resource)],
            "scopeSpans": [["scope": scope(), "spans": spans]],
        ]]]
    }
}
