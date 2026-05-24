import AppKit
import VibeSignalCore

enum TrafficLightIcon {
    static func image(for state: SignalState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        drawCircle(in: NSRect(x: 2, y: 2, width: 14, height: 14), state: state, stroke: true)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func dot(for state: SignalState) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        drawCircle(in: NSRect(x: 1, y: 1, width: 10, height: 10), state: state, stroke: false)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func drawCircle(in rect: NSRect, state: SignalState, stroke: Bool) {
        let path = NSBezierPath(ovalIn: rect)
        color(for: state).setFill()
        path.fill()

        if stroke {
            NSColor.black.withAlphaComponent(0.24).setStroke()
            path.lineWidth = 1
            path.stroke()

            let highlightRect = NSRect(
                x: rect.minX + rect.width * 0.24,
                y: rect.minY + rect.height * 0.56,
                width: rect.width * 0.36,
                height: rect.height * 0.24
            )
            NSColor.white.withAlphaComponent(0.38).setFill()
            NSBezierPath(ovalIn: highlightRect).fill()
        }
    }

    private static func color(for state: SignalState) -> NSColor {
        switch state {
        case .blocked:
            return NSColor(calibratedRed: 0.96, green: 0.18, blue: 0.16, alpha: 1)
        case .working:
            return NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.16, alpha: 1)
        case .idle:
            return NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.32, alpha: 1)
        case .error:
            return NSColor(calibratedRed: 0.78, green: 0.10, blue: 0.18, alpha: 1)
        case .unknown:
            return NSColor(calibratedWhite: 0.56, alpha: 1)
        }
    }
}
