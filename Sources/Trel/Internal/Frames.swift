import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif

/// Slow (>32ms) and frozen (>700ms) frame counts.
final class Frames: NSObject {
    static let shared = Frames()
    private var slow = 0
    private var frozen = 0
    private var last = CFTimeInterval(0)
    #if canImport(QuartzCore)
    private var link: CADisplayLink?
    #endif

    func start() {
        #if canImport(QuartzCore) && canImport(UIKit)
        DispatchQueue.main.async {
            let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        #endif
    }

    #if canImport(QuartzCore)
    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 {
            let dt = (link.timestamp - last) * 1000
            if dt > 700 { frozen += 1 }
            else if dt > 32 { slow += 1 }
        }
        last = link.timestamp
    }
    #endif

    func consume() -> (slow: Int, frozen: Int) {
        let out = (slow, frozen)
        slow = 0
        frozen = 0
        return out
    }
}
