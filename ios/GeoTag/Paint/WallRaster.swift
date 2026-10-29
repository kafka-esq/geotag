import CoreGraphics
import Foundation
import simd

/// A wall's paint as pixels. CPU rendering into an RGBA buffer keeps every phone pixel-identical and
/// lets us upload only the rectangle that changed each frame.
final class WallRaster {
    let width: Int
    let height: Int
    let pxPerMetre: Float
    let originX: Float   // wall metres at pixel column 0
    let originY: Float   // wall metres at pixel row `height` (rows run top-down)
    private(set) var pixels: [UInt8]
    private(set) var dirty: (Int, Int, Int, Int)? = nil  // x0, y0, x1, y1 in pixels, inclusive-exclusive

    init(canvasX0: Float, canvasY0: Float, canvasW: Float, canvasH: Float, pxPerMetre: Float = 112) {
        self.pxPerMetre = pxPerMetre
        width = max(8, Int((canvasW * pxPerMetre).rounded()))
        height = max(8, Int((canvasH * pxPerMetre).rounded()))
        originX = canvasX0
        originY = canvasY0
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    func clear() {
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        markAll()
    }

    func markAll() { dirty = (0, 0, width, height) }

    func takeDirty() -> (Int, Int, Int, Int)? {
        defer { dirty = nil }
        return dirty
    }

    /// Wall metres to pixel coordinates (row 0 at the top).
    @inline(__always) func px(_ x: Float, _ y: Float) -> (Float, Float) {
        ((x - originX) * pxPerMetre, Float(height) - (y - originY) * pxPerMetre)
    }

    func contains(_ x: Float, _ y: Float) -> Bool {
        let (u, v) = px(x, y)
        return u >= 0 && v >= 0 && u < Float(width) && v < Float(height)
    }

    // MARK: drawing

    func draw(_ piece: PieceData) {
        let cols = piece.colors.map { RGBA8(css: $0) }
        func col(_ i: Float) -> RGBA8 { let k = Int(i); return k >= 0 && k < cols.count ? cols[k] : RGBA8(css: "#FF3D7F") }
        for d in piece.dabs ?? [] where d.count >= 7 {
            dab(x: d[0], y: d[1], r: d[2], alpha: d[3], stretch: d[4], angle: d[5], color: col(d[6]))
        }
        for s in piece.strokes ?? [] {
            stroke(s, color: col(Float(s.ci)))
        }
        for d in piece.drips ?? [] where d.count >= 5 {
            drip(x: d[0], y: d[1], length: d[2], width: d[3], color: col(d[4]))
        }
    }

    /// A soft elliptical spot of paint. stretch >= 1 elongates it along `angle` (radians, wall space).
    func dab(x: Float, y: Float, r: Float, alpha: Float, stretch: Float, angle: Float, color: RGBA8) {
        let (cx, cy) = px(x, y)
        let rp = max(0.6, r * pxPerMetre)
        let major = rp * max(1, stretch), minor = rp
        let ext = major + 1.5
        let x0 = max(0, Int(cx - ext)), x1 = min(width - 1, Int(cx + ext))
        let y0 = max(0, Int(cy - ext)), y1 = min(height - 1, Int(cy + ext))
        if x0 > x1 || y0 > y1 { return }
        // rows run downward, so flip the angle's vertical component
        let ca = cos(-angle), sa = sin(-angle)
        for py in y0...y1 {
            let dy = Float(py) + 0.5 - cy
            var i = (py * width + x0) * 4
            for pxx in x0...x1 {
                let dx = Float(pxx) + 0.5 - cx
                let u = (dx * ca + dy * sa) / major
                let v = (-dx * sa + dy * ca) / minor
                let d2 = u * u + v * v
                if d2 < 1 {
                    // gaussian-ish falloff: dense middle, feathered edge like real spray
                    let f = (1 - d2) * (1 - d2)
                    blend(at: i, color, alpha * f)
                }
                i += 4
            }
        }
        mark(x0, y0, x1 + 1, y1 + 1)
    }

    /// A run of paint: a narrowing streak with a bead at the bottom.
    func drip(x: Float, y: Float, length: Float, width w: Float, color: RGBA8) {
        let steps = max(2, Int(length * pxPerMetre))
        for k in 0...steps {
            let t = Float(k) / Float(steps)
            let yy = y - length * t
            let ww = w * (1 - 0.45 * t)
            dab(x: x + 0.002 * sin(t * 9), y: yy, r: ww * 0.5, alpha: 0.85, stretch: 1, angle: 0, color: color)
        }
        dab(x: x, y: y - length, r: w * 0.75, alpha: 0.9, stretch: 1, angle: 0, color: color)
    }

    func stroke(_ s: PieceData.SketchStroke, color: RGBA8, from: Int = 0) {
        let n = s.p.count / 2
        if n == 0 { return }
        let r = max(0.002, s.w / 2)
        let spray = s.b == "s"
        let step = max(0.6 / pxPerMetre, r * (spray ? 0.5 : 0.25))
        if from == 0 { stamp(s.p[0], s.p[1], r, color, spray, seed: 1) }
        var i = max(1, from)
        while i < n {
            let ax = s.p[(i - 1) * 2], ay = s.p[(i - 1) * 2 + 1], bx = s.p[i * 2], by = s.p[i * 2 + 1]
            let len = hypot(bx - ax, by - ay)
            let k = max(1, Int(len / step))
            for j in 1...k {
                let t = Float(j) / Float(k)
                stamp(ax + (bx - ax) * t, ay + (by - ay) * t, r, color, spray, seed: i * 131 + j)
            }
            i += 1
        }
    }

    private func stamp(_ x: Float, _ y: Float, _ r: Float, _ c: RGBA8, _ spray: Bool, seed: Int) {
        if !spray {
            dab(x: x, y: y, r: r, alpha: 1, stretch: 1, angle: 0, color: c)
            // flatten the soft edge into a solid marker line
            dab(x: x, y: y, r: r * 0.8, alpha: 1, stretch: 1, angle: 0, color: c)
            return
        }
        var g = SplitMix(seed: UInt64(seed))
        dab(x: x, y: y, r: r * 1.2, alpha: 0.12, stretch: 1, angle: 0, color: c)
        for _ in 0..<6 {
            let a = g.next() * .pi * 2, d = r * 1.4 * g.next() * g.next()
            dab(x: x + cos(a) * d, y: y + sin(a) * d, r: r * 0.12, alpha: 0.7, stretch: 1, angle: 0, color: c)
        }
    }

    @inline(__always) private func blend(at i: Int, _ c: RGBA8, _ a: Float) {
        if a <= 0.002 { return }
        let da = Float(pixels[i + 3]) / 255
        let oa = a + da * (1 - a)
        if oa <= 0 { return }
        let k = da * (1 - a)
        pixels[i] = UInt8(min(255, (Float(c.r) * a + Float(pixels[i]) * k) / oa))
        pixels[i + 1] = UInt8(min(255, (Float(c.g) * a + Float(pixels[i + 1]) * k) / oa))
        pixels[i + 2] = UInt8(min(255, (Float(c.b) * a + Float(pixels[i + 2]) * k) / oa))
        pixels[i + 3] = UInt8(min(255, oa * 255))
    }

    private func mark(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        if let d = dirty { dirty = (min(d.0, x0), min(d.1, y0), max(d.2, x1), max(d.3, y1)) }
        else { dirty = (x0, y0, x1, y1) }
    }

    /// A CGImage of the whole wall, for previews and sharing.
    func cgImage() -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Fraction of the canvas that has paint, for "is this wall crowded" hints.
    func coverage(in rect: (Float, Float, Float, Float)) -> Float {
        let (a, b) = px(rect.0, rect.3), (c, d) = px(rect.2, rect.1)
        let x0 = max(0, Int(a)), x1 = min(width - 1, Int(c)), y0 = max(0, Int(b)), y1 = min(height - 1, Int(d))
        if x0 >= x1 || y0 >= y1 { return 0 }
        var hit = 0, total = 0
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 { if pixels[(y * width + x) * 4 + 3] > 40 { hit += 1 }; total += 1; x += 4 }
            y += 4
        }
        return total == 0 ? 0 : Float(hit) / Float(total)
    }
}

/// Tiny deterministic random numbers so spray speckle replays identically everywhere.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Float {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Float(z >> 40) / Float(1 << 24)
    }
}
