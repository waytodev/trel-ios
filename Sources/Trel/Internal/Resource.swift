import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Resource attributes for every payload plus best-effort device state per event.
final class Resource {
    let serviceName: String
    let release: String
    let bundleId: String
    let build: String?
    let environment: String
    let installId: String
    private let processStart = Date()

    init(options: TrelOptions) {
        let bundle = Bundle.main
        bundleId = bundle.bundleIdentifier ?? "app"
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        release = options.release ?? [shortVersion ?? "0.0.0", build].compactMap { $0 }.joined(separator: "+")
        serviceName = options.service ?? bundleId
        environment = options.environment

        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "to.trel.install_id") {
            installId = existing
        } else {
            installId = UUID().uuidString.lowercased()
            defaults.set(installId, forKey: "to.trel.install_id")
        }
    }

    static var machine: String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        let bytes = mirror.children.compactMap { $0.value as? Int8 }.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static var osName: String {
        #if os(iOS)
        return "ios"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(macOS)
        return "macos"
        #else
        return "apple"
        #endif
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    func attributes() -> [String: Any] {
        [
            Attr.serviceName: serviceName,
            Attr.serviceVersion: release,
            Attr.environment: environment,
            Attr.osName: Resource.osName,
            Attr.osVersion: Resource.osVersion,
            Attr.deviceModel: Resource.machine,
            Attr.deviceManufacturer: "Apple",
            Attr.deviceId: installId,
            Attr.sdkName: Trel.sdkName,
            Attr.sdkVersion: Trel.sdkVersion,
            Attr.platform: Resource.osName == "ios" ? "ios" : Resource.osName,
            Attr.appPackage: bundleId,
            Attr.appBuild: build ?? "",
        ]
    }

    var uptimeMs: Int { Int(Date().timeIntervalSince(processStart) * 1000) }

    func deviceState(into attrs: inout [String: Any]) {
        #if canImport(UIKit) && !os(tvOS)
        DispatchQueue.mainIfNeededSync {
            let device = UIDevice.current
            if device.isBatteryMonitoringEnabled, device.batteryLevel >= 0 {
                attrs[Attr.batteryLevel] = Int(device.batteryLevel * 100)
            }
            switch device.orientation {
            case .portrait, .portraitUpsideDown: attrs[Attr.orientation] = "portrait"
            case .landscapeLeft, .landscapeRight: attrs[Attr.orientation] = "landscape"
            default: break
            }
        }
        #endif
        attrs[Attr.freeMemory] = Resource.freeMemoryBytes()
    }

    private static func freeMemoryBytes() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Int(vm_kernel_page_size)
        return (Int(stats.free_count) + Int(stats.inactive_count)) * pageSize
    }
}

extension DispatchQueue {
    /// Runs `block` on the main thread, synchronously when already there, otherwise skips (never blocks a crash path).
    static func mainIfNeededSync(_ block: () -> Void) {
        if Thread.isMainThread { block() }
    }
}
