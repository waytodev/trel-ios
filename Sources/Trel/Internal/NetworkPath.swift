import Foundation
import Network

/// Last known path, plus a callback when it changes (breadcrumb `app.connectivity`).
enum NetworkPath {
    private static let monitor = NWPathMonitor()
    private static let queue = DispatchQueue(label: "to.trel.network")
    private static var latest = "unknown"
    private static var onChange: ((String) -> Void)?

    static var current: String { latest }

    static func start(_ change: @escaping (String) -> Void) {
        onChange = change
        monitor.pathUpdateHandler = { path in
            let kind: String
            if path.status != .satisfied { kind = "none" }
            else if path.usesInterfaceType(.wifi) { kind = "wifi" }
            else if path.usesInterfaceType(.cellular) { kind = "cell" }
            else if path.usesInterfaceType(.wiredEthernet) { kind = "wired" }
            else { kind = "other" }
            if kind != latest {
                latest = kind
                change(kind)
            } else {
                latest = kind
            }
        }
        monitor.start(queue: queue)
    }
}
