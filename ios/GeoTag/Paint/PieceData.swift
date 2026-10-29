import Foundation

/// What a piece is made of, in wall metres (x right, y up, origin at the wall's reference point).
///
/// Spray pieces are a list of dabs, recorded about 60 times a second while the trigger is held.
/// Each dab is [x, y, radius, alpha, stretch, angle, colourIndex]. Drips are [x, y, length, width, colourIndex].
/// Sketch pieces are polylines: colour, width in metres, brush, and flat x,y pairs.
/// Everything replays deterministically, so every phone renders the same pixels.
struct PieceData: Codable, Equatable {
    var v: Int = 2
    var colors: [String] = []
    var dabs: [[Float]]? = nil
    var drips: [[Float]]? = nil
    var strokes: [SketchStroke]? = nil

    struct SketchStroke: Codable, Equatable {
        var ci: Int
        var w: Float
        var b: String      // "m" marker, "s" spray
        var p: [Float]
    }

    mutating func colorIndex(_ css: String) -> Int {
        if let i = colors.firstIndex(of: css) { return i }
        colors.append(css)
        return colors.count - 1
    }

    var isEmpty: Bool { (dabs?.isEmpty ?? true) && (strokes?.isEmpty ?? true) && (drips?.isEmpty ?? true) }

    /// Bounding box in wall metres: x0, y0, x1, y1.
    var bounds: (Float, Float, Float, Float) {
        var x0 = Float.greatestFiniteMagnitude, y0 = x0, x1 = -x0, y1 = -x0
        func add(_ x: Float, _ y: Float, _ r: Float) {
            x0 = min(x0, x - r); y0 = min(y0, y - r); x1 = max(x1, x + r); y1 = max(y1, y + r)
        }
        for d in dabs ?? [] where d.count >= 3 { add(d[0], d[1], d[2] * (d.count > 4 ? d[4] : 1)) }
        for d in drips ?? [] where d.count >= 3 { add(d[0], d[1], 0.02); add(d[0], d[1] - d[2], 0.02) }
        for s in strokes ?? [] {
            var i = 0
            while i + 1 < s.p.count { add(s.p[i], s.p[i + 1], s.w); i += 2 }
        }
        if x0 > x1 { return (0, 0, 0, 0) }
        return (x0, y0, x1, y1)
    }

    /// Rough size in bytes once posted. The server caps a piece at about 700 KB.
    var estimatedBytes: Int { (dabs?.count ?? 0) * 48 + (strokes ?? []).reduce(0) { $0 + $1.p.count * 7 } + 200 }
}
