import Foundation

/// Mirror of `ATTR` in `@trel/shared/src/mobile.ts`. Keep the two in sync.
enum Attr {
    static let exceptionType = "exception.type"
    static let exceptionMessage = "exception.message"
    static let exceptionStacktrace = "exception.stacktrace"
    static let exceptionEscaped = "exception.escaped"
    static let mechanism = "trel.mechanism"
    static let threadName = "trel.thread.name"
    static let appState = "trel.app.state"
    static let appUptimeMs = "trel.app.uptime_ms"
    static let breadcrumbs = "trel.breadcrumbs"
    static let debugMeta = "trel.debug_meta"
    static let tagPrefix = "trel.tag."
    static let source = "trel.source"

    static let userId = "enduser.id"
    static let userEmail = "enduser.email"
    static let userName = "enduser.name"
    static let sessionId = "session.id"
    static let sessionPreviousId = "session.previous_id"
    static let sessionStatus = "session.status"
    static let signal = "trel.signal"

    static let serviceName = "service.name"
    static let serviceVersion = "service.version"
    static let environment = "deployment.environment"
    static let osName = "os.name"
    static let osVersion = "os.version"
    static let deviceModel = "device.model.identifier"
    static let deviceManufacturer = "device.manufacturer"
    static let deviceId = "device.id"
    static let sdkName = "telemetry.sdk.name"
    static let sdkVersion = "telemetry.sdk.version"
    static let platform = "trel.platform"
    static let appPackage = "trel.app.package"
    static let appBuild = "trel.app.build"

    static let networkType = "network.connection.type"
    static let batteryLevel = "device.battery_level"
    static let freeMemory = "trel.memory.free_bytes"
    static let orientation = "trel.orientation"

    static let httpMethod = "http.request.method"
    static let urlFull = "url.full"
    static let httpStatus = "http.response.status_code"
    static let serverAddress = "server.address"
}
