import Foundation

/// Configuration for `Trel.start(_:)`. Only `apiKey` is required.
public struct TrelOptions {
    /// Project ingest key (`trel_sk_…`) from Settings → API keys.
    public var apiKey: String
    /// Deployment environment; groups issues and release health.
    public var environment: String = "production"
    /// Release identifier. Defaults to `CFBundleShortVersionString+CFBundleVersion`.
    public var release: String?
    /// Service name shown in Trel. Defaults to the bundle identifier.
    public var service: String?
    /// Ingest base URL. Change only for self-hosted or regional deployments.
    public var endpoint: URL = URL(string: "https://ingest.trel.to")!
    /// Install the crash reporter (Mach / signal / NSException / Swift runtime traps).
    public var enableCrashReporting: Bool = true
    /// Report main-thread hangs (`AppHang`, mechanism `app_hang`) while the app is alive.
    public var enableAppHangs: Bool = true
    /// Main-thread stall duration before a hang is reported.
    public var appHangTimeout: TimeInterval = 2.0
    /// Swizzle `URLSession` to emit HTTP CLIENT spans and `http` breadcrumbs.
    public var enableNetwork: Bool = true
    /// Record `http` breadcrumbs from network instrumentation.
    public var enableNetworkBreadcrumbs: Bool = true
    /// Record `ui.lifecycle` breadcrumbs from `UIViewController.viewDidAppear`.
    public var enableViewControllerBreadcrumbs: Bool = true
    /// Also ship breadcrumbs as log records (billed as events). Off by default.
    public var breadcrumbsAsLogs: Bool = false
    /// Ring-buffer size for breadcrumbs attached to each exception (max 100).
    public var maxBreadcrumbs: Int = 100
    /// Minimum level for `Trel.log`.
    public var minLogLevel: TrelLevel = .debug
    /// Print SDK diagnostics to the console.
    public var debug: Bool = false
    /// Last chance to modify or drop an event. Return `nil` to drop.
    public var beforeSend: ((TrelEvent) -> TrelEvent?)?

    public init(apiKey: String, environment: String = "production") {
        self.apiKey = apiKey
        self.environment = environment
    }
}

/// Severity for `Trel.log` and `Trel.captureMessage`; maps onto OTLP severity numbers.
public enum TrelLevel: Int, Comparable {
    case debug = 5
    case info = 9
    case warn = 13
    case error = 17
    case fatal = 21

    public static func < (lhs: TrelLevel, rhs: TrelLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        case .fatal: return "FATAL"
        }
    }

    var breadcrumbLabel: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warning"
        case .error, .fatal: return "error"
        }
    }
}

/// Something that happened before an error. Attached (last `maxBreadcrumbs`) to every exception.
public struct Breadcrumb {
    public var message: String
    /// `ui.lifecycle` · `app.lifecycle` · `http` · `navigation` · `user` · anything you like.
    public var category: String
    public var level: TrelLevel
    public var data: [String: Any]?
    public var timestamp: Date

    public init(message: String, category: String = "default", level: TrelLevel = .info, data: [String: Any]? = nil, timestamp: Date = Date()) {
        self.message = message
        self.category = category
        self.level = level
        self.data = data
        self.timestamp = timestamp
    }
}

/// Mutable view of an exception before it is queued; what `beforeSend` receives.
public struct TrelEvent {
    public var type: String
    public var message: String
    public var stacktrace: String
    public let mechanism: String
    public var attributes: [String: Any]

    /// True for crashes / hangs that terminated the process.
    public var isFatal: Bool { mechanism == "crash" || mechanism == "native" }
}
