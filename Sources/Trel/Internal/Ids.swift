import Foundation

enum Ids {
    private static func hex(_ bytes: Int) -> String {
        var out = ""
        out.reserveCapacity(bytes * 2)
        for _ in 0..<bytes {
            out += String(format: "%02x", UInt8.random(in: 0...255))
        }
        return out
    }

    static func traceId() -> String { hex(16) }
    static func spanId() -> String { hex(8) }

    /// Sortable file name: millis + random suffix.
    static func ulid() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let prefix = String(ms, radix: 16)
        return String(repeating: "0", count: max(0, 12 - prefix.count)) + prefix + hex(8)
    }
}
