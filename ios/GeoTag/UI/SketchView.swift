import SwiftUI

/// Sketch mode: the wall, flattened. Draw with a finger, then post it where you framed it.
struct SketchView: View {
    @EnvironmentObject var model: AppModel
    let frame: SketchFrame
    let done: (_ posted: Bool) -> Void

    @State private var strokes: [Line] = []
    @State private var current: Line?
    @State private var color = Theme.paints[0]
    @State private var brush = "m"
    @State private var size: CGFloat = 0.02   // fraction of the frame width
    @State private var posting = false

    struct Line: Identifiable {
        let id = UUID()
        var color: String
        var brush: String
        var size: CGFloat
        var points: [CGPoint]   // normalised, origin top-left
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(String(format: "%.1f × %.1f m of wall", frame.width, frame.height))
                    .font(Theme.mono(13)).foregroundStyle(Theme.mute)
                Spacer()
                Button("cancel") { done(false) }.buttonStyle(ChalkButton())
            }
            canvas
            palette
            HStack(spacing: 8) {
                toggle("marker", brush == "m") { brush = "m" }
                toggle("spray", brush == "s") { brush = "s" }
                Spacer(minLength: 4)
                ForEach([("S", 0.008), ("M", 0.02), ("L", 0.045), ("XL", 0.08)], id: \.0) { item in
                    toggle(item.0, abs(size - item.1) < 0.001) { size = item.1 }
                }
            }
            HStack(spacing: 10) {
                Button { _ = strokes.popLast() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(ChalkButton()).disabled(strokes.isEmpty)
                Button("clear") { strokes = [] }.buttonStyle(ChalkButton()).disabled(strokes.isEmpty)
                if model.practice {
                    Button("done") { done(false) }.buttonStyle(ChalkButton(fill: Theme.paint)).frame(maxWidth: .infinity)
                } else {
                    Button { Task { await post() } } label: {
                        Group { if posting { ProgressView() } else { Text("post").font(Theme.display(28)) } }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChalkButton(fill: strokes.isEmpty ? Theme.panel : Theme.paint))
                    .disabled(strokes.isEmpty || posting)
                }
            }
        }
        .padding(16)
        .background(Theme.ink.ignoresSafeArea())
    }

    private var canvas: some View {
        GeometryReader { geo in
            let s = geo.size
            ZStack {
                Image(decorative: frame.image, scale: 1).resizable()
                Canvas { ctx, size in
                    for line in strokes + (current.map { [$0] } ?? []) { draw(line, in: &ctx, size: size) }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let p = CGPoint(x: min(max(v.location.x / s.width, 0), 1), y: min(max(v.location.y / s.height, 0), 1))
                    if current == nil { current = Line(color: color, brush: brush, size: size, points: [p]) }
                    else if let last = current?.points.last, hypot(last.x - p.x, last.y - p.y) > 0.002 { current?.points.append(p) }
                }
                .onEnded { _ in if let c = current { strokes.append(c) }; current = nil })
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.chalk.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
        }
        .aspectRatio(CGFloat(frame.width / frame.height), contentMode: .fit)
    }

    private func draw(_ l: Line, in ctx: inout GraphicsContext, size: CGSize) {
        guard let first = l.points.first else { return }
        var path = Path()
        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
        for p in l.points.dropFirst() { path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height)) }
        if l.points.count == 1 { path.addLine(to: CGPoint(x: first.x * size.width + 0.5, y: first.y * size.height)) }
        let w = l.size * size.width
        let c = Color(css: l.color)
        if l.brush == "s" {
            var soft = ctx
            soft.addFilter(.blur(radius: w * 0.5))
            soft.stroke(path, with: .color(c.opacity(0.75)), style: StrokeStyle(lineWidth: w * 1.4, lineCap: .round, lineJoin: .round))
        } else {
            ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }
    }

    private var palette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Theme.paints, id: \.self) { hex in
                    Button { color = hex } label: {
                        Circle().fill(Color(css: hex)).frame(width: 34, height: 34)
                            .overlay(Circle().stroke(color == hex ? Theme.chalk : .black.opacity(0.5), lineWidth: color == hex ? 3 : 2))
                    }
                }
            }
        }
    }

    private func toggle(_ t: String, _ on: Bool, _ a: @escaping () -> Void) -> some View {
        Button(t, action: a).buttonStyle(ChalkButton(fill: on ? Theme.chalk : Theme.panel, fg: on ? Theme.ink : Theme.chalk))
    }

    /// Converts finger lines to wall metres and posts them.
    private func post() async {
        var data = PieceData()
        var out: [PieceData.SketchStroke] = []
        for l in strokes {
            var pts: [Float] = []
            for p in l.points {
                pts.append(((frame.x0 + Float(p.x) * frame.width) * 10000).rounded() / 10000)
                pts.append(((frame.y0 + (1 - Float(p.y)) * frame.height) * 10000).rounded() / 10000)
            }
            let ci = data.colorIndex(l.color)
            out.append(PieceData.SketchStroke(ci: ci, w: Float(l.size) * frame.width, b: l.brush, p: pts))
        }
        data.strokes = out
        posting = true
        defer { posting = false }
        do {
            let dto = try await Poster.post(data, kind: "sketch", on: frame.wall, ar: model.ar)
            frame.wall.canvas.raster.draw(dto.data)
            model.ar.spray.haptics.success()
            model.show("posted. it's on the wall")
            done(true)
        } catch {
            model.show(error.localizedDescription)
        }
    }
}
