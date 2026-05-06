import AppKit

enum VisualizerStyle: String, CaseIterable {
    case bars = "Bars"
    case barsInverted = "Bars (Inverted)"
    case mirror = "Mirror Bars"
    case wave = "Wave"
    case blocks = "Blocks"
    case line = "Line"
    case circle = "Circle Blob"
    case circleRays = "Circle Rays"
    case circleDots = "Circle Dots"
}

enum ColorScheme: String, CaseIterable {
    case cyan = "Cyan"
    case purple = "Purple"
    case green = "Green"
    case orange = "Orange"
    case pink = "Pink"
    case rainbow = "Rainbow"
    case white = "White"
}

final class VisualizerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    var bands: [Float] = Array(repeating: 0, count: 16) {
        didSet { needsDisplay = true }
    }

    var style: VisualizerStyle = .bars {
        didSet { needsDisplay = true }
    }

    var colorScheme: ColorScheme = .cyan {
        didSet { needsDisplay = true }
    }

    var brightness: CGFloat = 1.0 {
        didSet { alphaValue = brightness }
    }

    private let verticalPadding: CGFloat = 3.0
    private let barGap: CGFloat = 1.0

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Compute bar count and width dynamically based on available width
    private var barLayout: (count: Int, width: CGFloat) {
        let available = bounds.width - 4 // 2px margin each side
        let minBarWidth: CGFloat = 2.5
        let maxBarWidth: CGFloat = 4.0
        // Try to fit as many bars as possible at a nice width
        let idealWidth: CGFloat = 3.0
        let count = max(4, Int(available / (idealWidth + barGap)))
        let width = max(minBarWidth, min(maxBarWidth, (available - CGFloat(count - 1) * barGap) / CGFloat(count)))
        return (count, width)
    }

    /// Interpolate bands array to match a target count
    private func interpolatedBands(targetCount: Int) -> [CGFloat] {
        let src = bands
        guard src.count >= 2, targetCount >= 2 else {
            return Array(repeating: 0, count: targetCount)
        }
        var result = [CGFloat](repeating: 0, count: targetCount)
        for i in 0..<targetCount {
            let srcPos = Float(i) / Float(targetCount - 1) * Float(src.count - 1)
            let low = Int(srcPos)
            let high = min(low + 1, src.count - 1)
            let frac = srcPos - Float(low)
            result[i] = CGFloat(src[low] * (1 - frac) + src[high] * frac)
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else { return }

        switch style {
        case .bars:         drawBars(inverted: false)
        case .barsInverted: drawBars(inverted: true)
        case .mirror:       drawMirror()
        case .wave:         drawWave()
        case .blocks:       drawBlocks()
        case .line:         drawLine()
        case .circle:       drawCircleBlob()
        case .circleRays:   drawCircleRays()
        case .circleDots:   drawCircleDots()
        }
    }

    // MARK: - Color helpers

    private func baseHue(forIndex i: Int, ofCount count: Int) -> CGFloat {
        switch colorScheme {
        case .cyan:    return 0.52 + CGFloat(i) / CGFloat(count) * 0.12
        case .purple:  return 0.75 + CGFloat(i) / CGFloat(count) * 0.08
        case .green:   return 0.30 + CGFloat(i) / CGFloat(count) * 0.10
        case .orange:  return 0.06 + CGFloat(i) / CGFloat(count) * 0.06
        case .pink:    return 0.90 + CGFloat(i) / CGFloat(count) * 0.08
        case .rainbow: return CGFloat(i) / CGFloat(count)
        case .white:   return 0
        }
    }

    private func color(forIndex i: Int, ofCount count: Int, value: CGFloat) -> NSColor {
        if colorScheme == .white {
            let b = isDark ? (0.5 + value * 0.5) : (0.1 + value * 0.5)
            return NSColor(white: b, alpha: 0.6 + value * 0.4)
        }
        let hue = baseHue(forIndex: i, ofCount: count)
        let sat = colorScheme == .rainbow ? 0.8 : (0.6 + value * 0.35)
        let bri = isDark ? (0.45 + value * 0.55) : (0.25 + value * 0.45)
        let alpha = 0.6 + value * 0.4
        return NSColor(calibratedHue: hue, saturation: sat, brightness: bri, alpha: alpha)
    }

    private func strokeColor(value: CGFloat = 0.7) -> NSColor {
        if colorScheme == .white {
            return isDark ? NSColor.white.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.7)
        }
        let hue = baseHue(forIndex: 0, ofCount: 1)
        let bri = isDark ? 0.9 : 0.5
        return NSColor(calibratedHue: hue, saturation: 0.8, brightness: bri, alpha: 0.85)
    }

    private func fillColor(value: CGFloat = 0.5) -> NSColor {
        return strokeColor(value: value).withAlphaComponent(0.2)
    }

    // MARK: - Bars

    private func drawBars(inverted: Bool) {
        let layout = barLayout
        let values = interpolatedBands(targetCount: layout.count)
        let height = bounds.height - verticalPadding * 2
        let totalWidth = CGFloat(layout.count) * layout.width + CGFloat(layout.count - 1) * barGap
        let xOffset = (bounds.width - totalWidth) / 2

        for i in 0..<layout.count {
            let x = xOffset + CGFloat(i) * (layout.width + barGap)
            let value = values[i]
            let barHeight = max(2, value * height)
            let y = inverted ? verticalPadding : verticalPadding + (height - barHeight)

            let rect = CGRect(x: x, y: y, width: layout.width, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            color(forIndex: i, ofCount: layout.count, value: value).setFill()
            path.fill()
        }
    }

    // MARK: - Mirror

    private func drawMirror() {
        let layout = barLayout
        let values = interpolatedBands(targetCount: layout.count)
        let height = bounds.height - verticalPadding * 2
        let halfHeight = height / 2
        let totalWidth = CGFloat(layout.count) * layout.width + CGFloat(layout.count - 1) * barGap
        let xOffset = (bounds.width - totalWidth) / 2
        let centerY = verticalPadding + halfHeight

        for i in 0..<layout.count {
            let x = xOffset + CGFloat(i) * (layout.width + barGap)
            let value = values[i]
            let barHeight = max(1, value * halfHeight)

            let c = color(forIndex: i, ofCount: layout.count, value: value)

            let topRect = CGRect(x: x, y: centerY, width: layout.width, height: barHeight)
            c.setFill()
            NSBezierPath(roundedRect: topRect, xRadius: 0.5, yRadius: 0.5).fill()

            let bottomRect = CGRect(x: x, y: centerY - barHeight, width: layout.width, height: barHeight)
            c.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: bottomRect, xRadius: 0.5, yRadius: 0.5).fill()
        }
    }

    // MARK: - Wave

    private func drawWave() {
        let layout = barLayout
        let values = interpolatedBands(targetCount: layout.count)
        let height = bounds.height - verticalPadding * 2
        let totalWidth = CGFloat(layout.count) * layout.width + CGFloat(layout.count - 1) * barGap
        let xOffset = (bounds.width - totalWidth) / 2
        let centerY = verticalPadding + height / 2
        guard layout.count >= 2 else { return }

        for (mirror, alpha) in [(false, 0.9), (true, 0.45)] {
            let path = NSBezierPath()
            let sign: CGFloat = mirror ? -1 : 1
            let firstX = xOffset + layout.width / 2
            path.move(to: NSPoint(x: firstX, y: centerY + sign * values[0] * height / 2))
            for i in 1..<layout.count {
                let prevX = xOffset + CGFloat(i - 1) * (layout.width + barGap) + layout.width / 2
                let currX = xOffset + CGFloat(i) * (layout.width + barGap) + layout.width / 2
                let midX = (prevX + currX) / 2
                path.curve(
                    to: NSPoint(x: currX, y: centerY + sign * values[i] * height / 2),
                    controlPoint1: NSPoint(x: midX, y: centerY + sign * values[i-1] * height / 2),
                    controlPoint2: NSPoint(x: midX, y: centerY + sign * values[i] * height / 2)
                )
            }
            strokeColor().withAlphaComponent(alpha).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    // MARK: - Blocks

    private func drawBlocks() {
        let layout = barLayout
        let values = interpolatedBands(targetCount: layout.count)
        let height = bounds.height - verticalPadding * 2
        let totalWidth = CGFloat(layout.count) * layout.width + CGFloat(layout.count - 1) * barGap
        let xOffset = (bounds.width - totalWidth) / 2
        let blockH: CGFloat = 3.0
        let blockGap: CGFloat = 1.0
        let maxBlocks = Int(height / (blockH + blockGap))

        for i in 0..<layout.count {
            let x = xOffset + CGFloat(i) * (layout.width + barGap)
            let value = values[i]
            let active = max(0, Int(value * CGFloat(maxBlocks)))
            let litColor = color(forIndex: i, ofCount: layout.count, value: value)
            let dimColor: NSColor = isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.06)

            for b in 0..<maxBlocks {
                let y = verticalPadding + CGFloat(b) * (blockH + blockGap)
                let rect = CGRect(x: x, y: y, width: layout.width, height: blockH)
                (b < active ? litColor : dimColor).setFill()
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    // MARK: - Line

    private func drawLine() {
        let layout = barLayout
        let values = interpolatedBands(targetCount: layout.count)
        let height = bounds.height - verticalPadding * 2
        let totalWidth = CGFloat(layout.count) * layout.width + CGFloat(layout.count - 1) * barGap
        let xOffset = (bounds.width - totalWidth) / 2
        guard layout.count >= 2 else { return }

        let fillPath = NSBezierPath()
        let strokePath = NSBezierPath()
        var points = [(CGFloat, CGFloat)]()
        for i in 0..<layout.count {
            let x = xOffset + CGFloat(i) * (layout.width + barGap) + layout.width / 2
            points.append((x, verticalPadding + values[i] * height))
        }

        fillPath.move(to: NSPoint(x: points[0].0, y: verticalPadding))
        fillPath.line(to: NSPoint(x: points[0].0, y: points[0].1))
        strokePath.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for i in 1..<points.count {
            let midX = (points[i-1].0 + points[i].0) / 2
            fillPath.curve(to: NSPoint(x: points[i].0, y: points[i].1),
                           controlPoint1: NSPoint(x: midX, y: points[i-1].1),
                           controlPoint2: NSPoint(x: midX, y: points[i].1))
            strokePath.curve(to: NSPoint(x: points[i].0, y: points[i].1),
                             controlPoint1: NSPoint(x: midX, y: points[i-1].1),
                             controlPoint2: NSPoint(x: midX, y: points[i].1))
        }
        fillPath.line(to: NSPoint(x: points.last!.0, y: verticalPadding))
        fillPath.close()

        fillColor().setFill()
        fillPath.fill()
        strokeColor().setStroke()
        strokePath.lineWidth = 1.5
        strokePath.stroke()

        let sc = strokeColor()
        for (x, y) in points {
            sc.setFill()
            NSBezierPath(ovalIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)).fill()
        }
    }

    // MARK: - Circle Blob

    private func drawCircleBlob() {
        let segCount = bands.count
        let size = min(bounds.width, bounds.height)
        let cx = bounds.midX
        let cy = bounds.midY
        let baseR: CGFloat = size * 0.22
        let maxSpike: CGFloat = size * 0.26
        let angleStep = (2.0 * CGFloat.pi) / CGFloat(segCount)

        // Inner glow
        fillColor().setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - baseR * 0.8, y: cy - baseR * 0.8,
                                     width: baseR * 1.6, height: baseR * 1.6)).fill()

        // Outer blob
        var pts = [(CGFloat, CGFloat)]()
        for i in 0..<segCount {
            let angle = CGFloat(i) * angleStep - .pi / 2
            let v = CGFloat(bands[i])
            let r = baseR + v * maxSpike
            pts.append((cx + cos(angle) * r, cy + sin(angle) * r))
        }
        pts.append(pts[0])

        let fillP = NSBezierPath()
        let strokeP = NSBezierPath()
        fillP.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
        strokeP.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
        for i in 0..<pts.count - 1 {
            let curr = pts[i]
            let next = pts[(i + 1) % pts.count]
            let nn = pts[(i + 2) % pts.count]
            let cp1 = NSPoint(x: curr.0 + (next.0 - curr.0) * 0.5, y: curr.1 + (next.1 - curr.1) * 0.5)
            let cp2 = NSPoint(x: next.0 - (nn.0 - curr.0) * 0.15, y: next.1 - (nn.1 - curr.1) * 0.15)
            fillP.curve(to: NSPoint(x: next.0, y: next.1), controlPoint1: cp1, controlPoint2: cp2)
            strokeP.curve(to: NSPoint(x: next.0, y: next.1), controlPoint1: cp1, controlPoint2: cp2)
        }
        fillP.close()

        fillColor(value: 0.4).setFill()
        fillP.fill()
        strokeColor().setStroke()
        strokeP.lineWidth = 1.2
        strokeP.lineJoinStyle = .round
        strokeP.stroke()

        // Dots
        let sc = strokeColor()
        for i in 0..<segCount {
            let angle = CGFloat(i) * angleStep - .pi / 2
            let v = CGFloat(bands[i])
            let r = baseR + v * maxSpike
            let ds: CGFloat = 1.5 + v * 1.5
            let px = cx + cos(angle) * r
            let py = cy + sin(angle) * r
            sc.setFill()
            NSBezierPath(ovalIn: CGRect(x: px - ds/2, y: py - ds/2, width: ds, height: ds)).fill()
        }

        // Inner ring
        (isDark ? NSColor.white.withAlphaComponent(0.2) : NSColor.black.withAlphaComponent(0.15)).setStroke()
        let ir = NSBezierPath(ovalIn: CGRect(x: cx - baseR * 0.6, y: cy - baseR * 0.6,
                                              width: baseR * 1.2, height: baseR * 1.2))
        ir.lineWidth = 0.5
        ir.stroke()
    }

    // MARK: - Circle Rays

    private func drawCircleRays() {
        let segCount = bands.count
        let size = min(bounds.width, bounds.height)
        let cx = bounds.midX
        let cy = bounds.midY
        let innerR: CGFloat = size * 0.15
        let maxLen: CGFloat = size * 0.33
        let angleStep = (2.0 * CGFloat.pi) / CGFloat(segCount)
        let rayWidth: CGFloat = max(1.5, angleStep * innerR * 0.6)

        // Inner circle fill
        fillColor(value: 0.3).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - innerR, y: cy - innerR,
                                     width: innerR * 2, height: innerR * 2)).fill()

        // Rays
        for i in 0..<segCount {
            let angle = CGFloat(i) * angleStep - .pi / 2
            let v = CGFloat(bands[i])
            let len = max(2, v * maxLen)

            let x1 = cx + cos(angle) * innerR
            let y1 = cy + sin(angle) * innerR
            let x2 = cx + cos(angle) * (innerR + len)
            let y2 = cy + sin(angle) * (innerR + len)

            let path = NSBezierPath()
            path.move(to: NSPoint(x: x1, y: y1))
            path.line(to: NSPoint(x: x2, y: y2))
            path.lineWidth = rayWidth
            path.lineCapStyle = .round

            color(forIndex: i, ofCount: segCount, value: v).setStroke()
            path.stroke()
        }

        // Inner circle stroke
        strokeColor().withAlphaComponent(0.5).setStroke()
        let ic = NSBezierPath(ovalIn: CGRect(x: cx - innerR, y: cy - innerR,
                                              width: innerR * 2, height: innerR * 2))
        ic.lineWidth = 0.8
        ic.stroke()
    }

    // MARK: - Circle Dots

    private func drawCircleDots() {
        let segCount = bands.count
        let size = min(bounds.width, bounds.height)
        let cx = bounds.midX
        let cy = bounds.midY
        let baseR: CGFloat = size * 0.28
        let maxDisplace: CGFloat = size * 0.18
        let angleStep = (2.0 * CGFloat.pi) / CGFloat(segCount)

        // Base ring
        (isDark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.08)).setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: cx - baseR, y: cy - baseR,
                                                width: baseR * 2, height: baseR * 2))
        ring.lineWidth = 0.5
        ring.stroke()

        // Dots that move outward with amplitude
        for i in 0..<segCount {
            let angle = CGFloat(i) * angleStep - .pi / 2
            let v = CGFloat(bands[i])
            let r = baseR + v * maxDisplace
            let px = cx + cos(angle) * r
            let py = cy + sin(angle) * r

            // Dot size scales with value
            let dotSize: CGFloat = 2 + v * 4

            // Connecting line from base ring to dot
            let bx = cx + cos(angle) * baseR
            let by = cy + sin(angle) * baseR
            let linePath = NSBezierPath()
            linePath.move(to: NSPoint(x: bx, y: by))
            linePath.line(to: NSPoint(x: px, y: py))
            linePath.lineWidth = 0.6
            color(forIndex: i, ofCount: segCount, value: v).withAlphaComponent(0.4).setStroke()
            linePath.stroke()

            // Dot
            color(forIndex: i, ofCount: segCount, value: v).setFill()
            NSBezierPath(ovalIn: CGRect(x: px - dotSize/2, y: py - dotSize/2,
                                         width: dotSize, height: dotSize)).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }
}
