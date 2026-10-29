import ARKit
import Combine
import SwiftUI
import simd

/// The camera screen: look at art, spray with the can, or sketch flat.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        MainScreen(ar: model.ar, spray: model.ar.spray)
    }
}

enum Mode: String, CaseIterable { case look, spray, sketch }

enum Sheet: Identifiable {
    case piece(PieceDTO)
    case map
    case activity
    case me
    case wall(String)
    var id: String {
        switch self {
        case .piece(let p): return "piece-\(p.id)"
        case .map: return "map"
        case .activity: return "activity"
        case .me: return "me"
        case .wall(let w): return "wall-\(w)"
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct MainScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ar: ARController
    @ObservedObject var spray: SprayEngine
    @State private var mode: Mode = .look
    @State private var sheet: Sheet?
    @State private var sketch: SketchFrame?
    @State private var holding = false
    @State private var posting = false
    @State private var confirmScrap = false

    var body: some View {
        ZStack {
            ARViewContainer(view: ar.view).ignoresSafeArea()
            gestureLayer
            if mode != .look || spray.phase == .locked { Crosshair(ok: crosshairOK).allowsHitTesting(false) }
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottom
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            if spray.phase == .locked { pressureGauge }
        }
        .onAppear { ar.start(practice: model.practice) }
        .onDisappear { ar.pause() }
        .onChange(of: mode) { _, m in
            switch m {
            case .look: spray.stop()
            case .spray, .sketch: if spray.phase != .aiming { spray.unlock(); spray.beginAiming() }
            }
        }
        .onReceive(ar.$toast.compactMap { $0 }) { t in model.show(t); ar.toast = nil }
        .sheet(item: $sheet) { s in
            switch s {
            case .piece(let p): PieceSheet(piece: p) { sheet = .wall(p.wall_id) }
            case .map: MapScreen { id in sheet = .wall(id) }
            case .activity: ActivityView { id in sheet = .wall(id) }
            case .me: ProfileView()
            case .wall(let id): WallDetailView(wallId: id)
            }
        }
        .fullScreenCover(item: $sketch) { f in
            SketchView(frame: f) { posted in
                sketch = nil
                spray.unlock(keepDraft: posted)
                if posted { mode = .look }
            }
        }
        .confirmationDialog("scrap this?", isPresented: $confirmScrap, titleVisibility: .visible) {
            Button("scrap it", role: .destructive) { spray.unlock() }
        } message: { Text("what you sprayed since locking on goes away.") }
        .statusBarHidden(spray.phase == .locked)
    }

    private var crosshairOK: Bool {
        if spray.phase == .locked { return spray.distance.map { $0 <= SprayEngine.maxDistance } ?? false }
        return ar.candidate?.ok ?? false
    }

    // MARK: gestures

    @ViewBuilder private var gestureLayer: some View {
        if spray.phase == .locked {
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !holding { holding = true; spray.press() } }
                    .onEnded { _ in holding = false; spray.release() })
        } else if mode == .look {
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                .gesture(SpatialTapGesture().onEnded { e in
                    guard let (w, p) = ar.pick(e.location), let piece = w.piece(at: p) else { return }
                    sheet = .piece(piece)
                })
        }
    }

    // MARK: top

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusText).font(Theme.mono(12)).foregroundStyle(Theme.chalk).lineLimit(1)
            }
            .pill()
            Spacer(minLength: 4)
            if model.practice {
                Button("exit practice") { spray.stop(); model.leavePractice() }
                    .font(Theme.body(13, .semibold)).pill(Theme.paint)
            } else if spray.phase != .locked {
                iconButton("map") { sheet = .map }
                iconButton("bell") { sheet = .activity }
                iconButton("person.crop.circle") { sheet = .me }
            }
        }
        .padding(.top, 6)
    }

    private func iconButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.chalk)
                .frame(width: 42, height: 42).background(Theme.panel, in: Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
        }
    }

    private var statusText: String {
        if model.practice { return "practice · nothing is saved" }
        switch ar.loc {
        case .starting(let s), .localizing(let s): return s
        case .failed(let s): return s
        case .ready:
            let acc = ar.accuracy.map { String(format: "±%.1f m", $0) } ?? ""
            let n = ar.store.all.filter { $0.visible && !$0.pieces.isEmpty }.count
            return ar.geoGoodForPosting ? "locked \(acc) · \(n) walls" : "almost \(acc) · keep looking around"
        }
    }

    private var statusColor: Color {
        if model.practice { return Theme.cap }
        if ar.geoGoodForPosting { return Theme.go }
        if ar.geoReady { return Theme.cap }
        if case .failed = ar.loc { return Theme.paint }
        return Theme.paint.opacity(0.7)
    }

    // MARK: bottom

    @ViewBuilder private var bottom: some View {
        if spray.phase == .locked, mode == .spray {
            lockedControls
        } else {
            VStack(spacing: 12) {
                if mode == .look { lookHint } else { aimPanel }
                modeBar
            }
        }
    }

    private var lookHint: some View {
        Text(ar.geoReady || model.practice ? "tap a piece to see who painted it" : "hold up your phone and look at the buildings around you")
            .font(Theme.body(14, .semibold)).foregroundStyle(Theme.chalk)
            .shadow(color: .black.opacity(0.8), radius: 3)
            .multilineTextAlignment(.center)
    }

    private var aimPanel: some View {
        VStack(spacing: 10) {
            if let c = ar.candidate {
                VStack(spacing: 4) {
                    Text(candidateLine(c)).font(Theme.mono(13)).foregroundStyle(Theme.chalk)
                    if let p = c.problems.first {
                        Text(p).font(Theme.body(14, .semibold)).foregroundStyle(Theme.cap)
                    } else if c.distance < SprayEngine.lockMin {
                        Text("step back a little to lock on").font(Theme.body(14, .semibold)).foregroundStyle(Theme.cap)
                    } else if let w = c.existing, !w.pieces.isEmpty {
                        Text("\(w.pieces.count) piece\(w.pieces.count == 1 ? "" : "s") on this wall. yours goes on top")
                            .font(Theme.body(14, .semibold)).foregroundStyle(Theme.go)
                    } else {
                        Text("fresh wall").font(Theme.body(14, .semibold)).foregroundStyle(Theme.go)
                    }
                }
                .padding(12).frame(maxWidth: .infinity).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("aim the crosshair at a big flat wall, 1 to 6 metres away")
                    .font(Theme.body(14, .semibold)).foregroundStyle(Theme.chalk)
                    .padding(12).frame(maxWidth: .infinity).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            Button {
                guard let c = ar.candidate else { return }
                if mode == .spray { spray.lock(c) } else { frameSketch(c) }
            } label: {
                Text(mode == .spray ? "lock on" : "frame it").font(Theme.display(34)).frame(maxWidth: .infinity)
            }
            .buttonStyle(ChalkButton(fill: canLock ? Theme.paint : Theme.panel))
            .disabled(!canLock)
        }
    }

    private var canLock: Bool {
        guard let c = ar.candidate, c.ok else { return false }
        guard c.distance >= SprayEngine.lockMin, c.distance <= SprayEngine.lockMax else { return false }
        return model.practice || ar.geoReady
    }

    private func candidateLine(_ c: WallCandidate) -> String {
        var s = String(format: "wall %.1f m away", c.distance)
        if let z = c.size { s += String(format: " · %.1f × %.1f m", z.x, z.y) }
        return s
    }

    private var modeBar: some View {
        HStack(spacing: 6) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button { mode = m } label: {
                    Text(m.rawValue)
                        .font(m == mode ? Theme.display(26) : Theme.body(15, .semibold))
                        .foregroundStyle(m == mode ? Theme.ink : Theme.chalk)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(m == mode ? Theme.chalk : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(5)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private var lockedControls: some View {
        VStack(spacing: 12) {
            if let h = spray.hint {
                Text(h).font(Theme.body(15, .semibold)).foregroundStyle(Theme.chalk)
                    .shadow(color: .black.opacity(0.9), radius: 3)
            }
            if let d = spray.distance {
                Text(String(format: "%.0f cm", d * 100)).font(Theme.mono(13)).foregroundStyle(Theme.mute)
            }
            palette
            HStack(spacing: 10) {
                Button("unlock") { if spray.draftDabs > 0 { confirmScrap = true } else { spray.unlock() } }
                    .buttonStyle(ChalkButton())
                Button { spray.undoBurst() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(ChalkButton())
                    .disabled(spray.draftDabs == 0)
                if model.practice {
                    Button("wipe") { spray.unlock(); spray.beginAiming() }
                        .buttonStyle(ChalkButton(fill: Theme.paint))
                } else {
                    Button { Task { await postSpray() } } label: {
                        Group { if posting { ProgressView() } else { Text("post").font(Theme.display(28)) } }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChalkButton(fill: spray.draftDabs > 0 ? Theme.paint : Theme.panel))
                    .disabled(spray.draftDabs == 0 || posting)
                }
            }
        }
        .allowsHitTesting(!holding)
    }

    private var palette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Theme.paints, id: \.self) { hex in
                    Button { spray.color = hex } label: {
                        Circle().fill(Color(css: hex)).frame(width: 38, height: 38)
                            .overlay(Circle().stroke(spray.color == hex ? Theme.chalk : Color.black.opacity(0.5),
                                                     lineWidth: spray.color == hex ? 4 : 2))
                            .scaleEffect(spray.color == hex ? 1.12 : 1)
                    }
                    .accessibilityLabel("paint \(hex)")
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
        }
    }

    private var pressureGauge: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Capsule().fill(Theme.panel).frame(width: 14, height: 150)
                    Capsule().fill(spray.pressure < 0.18 ? Theme.cap : Color(css: spray.color))
                        .frame(width: 14, height: max(8, 150 * CGFloat(spray.pressure)))
                }
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                Text("shake").font(Theme.mono(10)).foregroundStyle(spray.pressure < 0.25 ? Theme.cap : Theme.mute)
            }
            .padding(.trailing, 10)
        }
        .allowsHitTesting(false)
    }

    // MARK: actions

    private func postSpray() async {
        guard let w = spray.wall else { return }
        posting = true
        defer { posting = false }
        do {
            _ = try await Poster.post(spray.takeDraft(), kind: "spray", on: w, ar: ar)
            spray.didPost()
            spray.haptics.success()
            spray.unlock(keepDraft: true)
            mode = .look
            model.show("posted. it's on the wall")
        } catch {
            model.show(error.localizedDescription)
        }
    }

    private func frameSketch(_ c: WallCandidate) {
        let w = spray.lockForSketch(c)
        let local = simd_inverse(w.worldFromWall) * SIMD4(c.frame.position, 1)
        if let f = SketchCapture.capture(ar: ar, wall: w, center: SIMD2(local.x, local.y)) {
            sketch = f
        } else {
            spray.unlock()
            model.show("couldn't grab the wall. try again")
        }
    }
}

extension SketchFrame: Identifiable { var id: String { "\(wall.id)-\(x0)-\(y0)" } }

struct Crosshair: View {
    var ok: Bool
    var body: some View {
        ZStack {
            Circle().stroke(ok ? Theme.go : Theme.chalk.opacity(0.8), lineWidth: 2).frame(width: 34, height: 34)
            Circle().fill(ok ? Theme.go : Theme.paint).frame(width: 6, height: 6)
            ForEach(0..<4) { i in
                Rectangle().fill(Theme.chalk.opacity(0.9)).frame(width: 2, height: 10)
                    .offset(y: -26).rotationEffect(.degrees(Double(i) * 90))
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
    }
}
