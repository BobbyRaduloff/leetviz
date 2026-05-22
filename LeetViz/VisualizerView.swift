import AppKit

final class VisualizerView: NSView {
    private var bands: [Float] = []
    private var waveform: [Float] = []
    private var level: Float = 0
    private var lastDrawnAllZero: Bool = true

    var style: VisualizerStyle = .bars {
        didSet { needsDisplay = true }
    }
    var accent: AccentColor = .cyan {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override var wantsDefaultClipping: Bool { false }

    /// Update the displayed state. Returns true if a redraw was scheduled.
    @discardableResult
    func update(bands: [Float], waveform: [Float], level: Float) -> Bool {
        self.bands = bands
        self.waveform = waveform
        self.level = level

        let allZero = level < 0.001 && bands.allSatisfy({ $0 < 0.001 })
        if allZero && lastDrawnAllZero { return false }
        lastDrawnAllZero = allZero
        needsDisplay = true
        return true
    }

    func clear() {
        bands = []
        waveform = []
        level = 0
        lastDrawnAllZero = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        renderInto(ctx: ctx, rect: bounds)
    }

    /// Cached bitmap context — `NSImage.lockFocus` reconstructs an offscreen
    /// graphics context every call (expensive). Reusing a single CGBitmapContext
    /// across frames drops the per-frame render cost dramatically.
    private var bitmapCtx: CGContext?
    private var bitmapSize: NSSize = .zero
    private var bitmapScale: CGFloat = 0

    func renderImage(size: NSSize) -> NSImage {
        let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
        if bitmapCtx == nil || bitmapSize != size || bitmapScale != scale {
            bitmapCtx = Self.makeBitmapContext(size: size, scale: scale)
            bitmapSize = size
            bitmapScale = scale
        }
        guard let ctx = bitmapCtx else {
            // Fallback: lockFocus path if we couldn't allocate a bitmap context.
            let image = NSImage(size: size)
            image.lockFocusFlipped(false)
            if let g = NSGraphicsContext.current?.cgContext {
                g.clear(CGRect(origin: .zero, size: size))
                renderInto(ctx: g, rect: CGRect(origin: .zero, size: size))
            }
            image.unlockFocus()
            image.isTemplate = false
            return image
        }
        ctx.clear(CGRect(origin: .zero, size: size))
        renderInto(ctx: ctx, rect: CGRect(origin: .zero, size: size))
        guard let cg = ctx.makeImage() else { return NSImage(size: size) }
        let image = NSImage(cgImage: cg, size: size)
        image.isTemplate = false
        return image
    }

    private static func makeBitmapContext(size: NSSize, scale: CGFloat) -> CGContext? {
        let w = Int((size.width * scale).rounded())
        let h = Int((size.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedFirst.rawValue
              | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: bi
        ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        return ctx
    }

    private func renderInto(ctx: CGContext, rect: CGRect) {
        switch style {
        case .bars:     drawBars(ctx: ctx, rect: rect)
        case .waveform: drawWaveform(ctx: ctx, rect: rect)
        case .blocks:   drawBlocks(ctx: ctx, rect: rect)
        }
    }

    // MARK: - Bars
    // 16 bars growing from the bottom; full accent color, no opacity tricks.
    // When silent, the row of baseline pips keeps the menu bar item visible.

    private let barCount = 16
    private let barBaseHeight: CGFloat = 2

    private func drawBars(ctx: CGContext, rect: CGRect) {
        let values: [Float] = bands.isEmpty
            ? [Float](repeating: 0, count: barCount)
            : bands
        let n = values.count
        let pad: CGFloat = 1
        let totalPad = pad * CGFloat(n - 1)
        let barW = max(1, (rect.width - totalPad) / CGFloat(n))
        ctx.setFillColor(accent.nsColor.cgColor)
        for (i, v) in values.enumerated() {
            let cv = CGFloat(max(0, min(1, v)))
            let h = max(barBaseHeight, cv * (rect.height - 2))
            let x = CGFloat(i) * (barW + pad)
            ctx.fill(CGRect(x: x, y: 1, width: barW, height: h))
        }
    }

    // MARK: - Waveform
    // Classic audio-editor look: for each pixel column, draw a vertical line
    // from the min sample to the max sample in that column's slice. Needs a
    // long-enough source window (~1024 samples) so we're not displaying
    // sub-millisecond chaos.

    private let waveGain: Float = 2.2

    private func drawWaveform(ctx: CGContext, rect: CGRect) {
        let mid = rect.height / 2
        ctx.setStrokeColor(accent.nsColor.cgColor)
        ctx.setLineWidth(1)

        let columns = max(1, Int(rect.width.rounded()))
        guard waveform.count > columns else {
            // Not enough samples yet: flat baseline so the item stays visible.
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: mid))
            ctx.addLine(to: CGPoint(x: rect.width, y: mid))
            ctx.strokePath()
            return
        }

        let amp = (rect.height / 2) - 1
        let samplesPerCol = Float(waveform.count) / Float(columns)
        ctx.beginPath()
        for col in 0..<columns {
            let start = Int(Float(col) * samplesPerCol)
            let end = min(Int(Float(col + 1) * samplesPerCol), waveform.count)
            var lo: Float = 0
            var hi: Float = 0
            for i in start..<end {
                let s = waveform[i] * waveGain
                if s < lo { lo = s }
                if s > hi { hi = s }
            }
            let yLo = mid + CGFloat(max(-1, lo)) * amp
            let yHi = mid + CGFloat(min(1, hi)) * amp
            let x = CGFloat(col) + 0.5
            // Ensure at least 1px so we always see a baseline at center.
            let yLo2 = min(yLo, mid - 0.5)
            let yHi2 = max(yHi, mid + 0.5)
            ctx.move(to: CGPoint(x: x, y: yLo2))
            ctx.addLine(to: CGPoint(x: x, y: yHi2))
        }
        ctx.strokePath()
    }

    // MARK: - Pulsing blocks
    // One block per frequency band, rendered as a vertically-centered pill that
    // pulses with that band's energy. Visually distinct from the bottom-grown
    // spectrum bars: same data, different feel.

    private let blockCount = 16

    private func drawBlocks(ctx: CGContext, rect: CGRect) {
        let values: [Float] = bands.isEmpty
            ? [Float](repeating: 0, count: blockCount)
            : bands
        let n = values.count
        let pad: CGFloat = 1.5
        let totalPad = pad * CGFloat(n - 1)
        let bw = max(1, (rect.width - totalPad) / CGFloat(n))
        let baseHeight: CGFloat = 2
        ctx.setFillColor(accent.nsColor.cgColor)
        for (i, v) in values.enumerated() {
            let cv = CGFloat(max(0, min(1, v)))
            // Near-linear height mapping. Earlier we used pow(cv, 0.7) to
            // flatter quiet bands, but combined with soft-clip it made every
            // band look the same height — kills the song-to-song variation.
            let h = max(baseHeight, cv * (rect.height - 2))
            let y = (rect.height - h) / 2
            let x = CGFloat(i) * (bw + pad)
            ctx.fill(CGRect(x: x, y: y, width: bw, height: h))
        }
    }
}
