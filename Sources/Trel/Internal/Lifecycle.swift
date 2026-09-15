import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// App state notifications → `app.lifecycle` breadcrumbs + transport cadence;
/// `UIViewController.viewDidAppear` swizzle → `ui.lifecycle` breadcrumbs.
final class Lifecycle {
    private unowned var trel: Trel!
    private(set) var isForeground = true

    init(trel: Trel?) {
        self.trel = trel
    }

    func attach(_ trel: Trel) { self.trel = trel }

    func install(viewControllerBreadcrumbs: Bool) {
        #if canImport(UIKit) && !os(watchOS)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.isForeground = true
            self?.trel.addBreadcrumb(Breadcrumb(message: "app active", category: "app.lifecycle"))
            self?.trel.transport.setForeground(true)
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.trel.addBreadcrumb(Breadcrumb(message: "app inactive", category: "app.lifecycle"))
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.isForeground = false
            self?.trel.addBreadcrumb(Breadcrumb(message: "app backgrounded", category: "app.lifecycle"))
            self?.trel.transport.setForeground(false)
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.isForeground = true
            self?.trel.addBreadcrumb(Breadcrumb(message: "app foregrounded", category: "app.lifecycle"))
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.trel.addBreadcrumb(Breadcrumb(message: "memory warning", category: "app.lifecycle", level: .warn))
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.trel.flush(timeout: 2)
        }
        if let state = UIApplication.sharedIfAvailable?.applicationState {
            isForeground = state != .background
        }
        if viewControllerBreadcrumbs { ViewControllerSwizzle.install(trel: trel) }
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
extension UIApplication {
    /// `UIApplication.shared` is unavailable in app extensions; resolve it dynamically.
    static var sharedIfAvailable: UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector) else { return nil }
        return UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
    }
}

private enum ViewControllerSwizzle {
    private static var installed = false
    private static weak var trel: Trel?

    static func install(trel: Trel) {
        guard !installed else { return }
        installed = true
        self.trel = trel
        let cls: AnyClass = UIViewController.self
        let original = #selector(UIViewController.viewDidAppear(_:))
        let swizzled = #selector(UIViewController.trel_viewDidAppear(_:))
        guard let om = class_getInstanceMethod(cls, original), let sm = class_getInstanceMethod(cls, swizzled) else { return }
        method_exchangeImplementations(om, sm)
    }

    static func record(_ vc: UIViewController) {
        let name = String(describing: type(of: vc))
        // Skip UIKit containers; the app's own screens are what matter in a breadcrumb trail.
        if name.hasPrefix("UI") || name.hasPrefix("_") { return }
        trel?.addBreadcrumb(Breadcrumb(message: "\(name) appeared", category: "ui.lifecycle", data: ["screen": name]))
    }
}

extension UIViewController {
    @objc fileprivate func trel_viewDidAppear(_ animated: Bool) {
        trel_viewDidAppear(animated) // calls the original (implementations are exchanged)
        ViewControllerSwizzle.record(self)
    }
}
#endif
