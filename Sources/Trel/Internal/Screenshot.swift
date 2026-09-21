import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum Screenshot {
    static func capture(maskText: Bool) -> Data? {
        #if canImport(UIKit) && !os(watchOS)
        let box = UnsafeMutablePointer<Data?>.allocate(capacity: 1)
        box.initialize(to: nil)
        let draw = {
            box.pointee = Screenshot.draw(maskText: maskText)
        }
        if Thread.isMainThread { draw() } else { DispatchQueue.main.sync(execute: draw) }
        let data = box.pointee
        box.deallocate()
        return data
        #else
        return nil
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private static func draw(maskText: Bool) -> Data? {
        guard let window = UIApplication.sharedIfAvailable?.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow })
            ?? UIApplication.sharedIfAvailable?.windows.first else { return nil }
        let bounds = window.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let target = CGSize(width: min(bounds.width, 480), height: bounds.height * min(1, 480 / max(bounds.width, 1)))
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let image = renderer.image { ctx in
            window.drawHierarchy(in: CGRect(origin: .zero, size: target), afterScreenUpdates: false)
            if maskText { mask(window, scale: target.width / max(bounds.width, 1), ctx: ctx.cgContext) }
        }
        return image.jpegData(compressionQuality: 0.35)
    }

    private static func mask(_ view: UIView, scale: CGFloat, ctx: CGContext) {
        func walk(_ v: UIView) {
            if v is UILabel || v is UITextView || v is UITextField {
                let rect = v.convert(v.bounds, to: nil)
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(rect.applying(CGAffineTransform(scaleX: scale, y: scale)))
            }
            v.subviews.forEach { walk($0) }
        }
        walk(view)
    }
    #endif
}
