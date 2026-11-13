import AppKit
import CoreslotKit

/// The "Slot" glyph: one rounded square, one colour, state carried by shape alone.
@MainActor
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    private static var cache: [String: NSImage] = [:]

    static func image(for state: IconState) -> NSImage {
        let key = String(describing: state)
        if let image = cache[key] { return image }
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = words(state)
        cache[key] = image
        return image
    }

    static func words(_ state: IconState) -> String {
        switch state {
        case .idle: "coreslot: nothing running"
        case .running: "coreslot: running"
        case .waiting: "coreslot: commands waiting"
        case .pressure: "coreslot: memory pressure"
        case .unavailable: "coreslot: unavailable"
        }
    }

    nonisolated private static let square = NSRect(x: 3, y: 1.5, width: 12, height: 12)

    nonisolated private static func draw(_ state: IconState) {
        let outline = NSBezierPath(roundedRect: square.insetBy(dx: 0.75, dy: 0.75), xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.5
        let ink = NSColor.black
        switch state {
        case .idle:
            ink.withAlphaComponent(0.45).setStroke()
            outline.stroke()
        case .running(let fill), .waiting(let fill):
            ink.setStroke()
            ink.setFill()
            outline.stroke()
            let inner = square.insetBy(dx: 2.75, dy: 2.75)
            // An empty share still shows a floor line, so a running slot never reads as idle.
            let h = fill > 0 ? inner.height * CGFloat(min(fill, 4)) / 4 : 0.75
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: h), xRadius: min(1, h / 2), yRadius: min(1, h / 2)).fill()
            if case .waiting = state {
                NSBezierPath(roundedRect: NSRect(x: 5.5, y: 15, width: 7, height: 2), xRadius: 1, yRadius: 1).fill()
            }
        case .pressure:
            ink.setFill()
            NSBezierPath(roundedRect: square, xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 8.1, y: 6.25, width: 1.8, height: 5.25), xRadius: 0.9, yRadius: 0.9).fill()
            NSBezierPath(ovalIn: NSRect(x: 8.1, y: 3.25, width: 1.8, height: 1.8)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        case .unavailable:
            ink.setStroke()
            outline.stroke()
            let stroke = NSBezierPath()
            stroke.move(to: NSPoint(x: square.minX + 1, y: square.minY + 1))
            stroke.line(to: NSPoint(x: square.maxX - 1, y: square.maxY - 1))
            stroke.lineWidth = 1.5
            stroke.lineCapStyle = .round
            stroke.stroke()
        }
    }
}
