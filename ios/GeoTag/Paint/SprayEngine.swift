import ARKit
import CoreMotion
import SwiftUI
import simd

/// Paint can mode. The phone is the can and the centre of the camera is the nozzle.
///
/// Physics, roughly like a real can:
/// - distance sets the spray cone: close is tight and dense, far is a wide faint mist
/// - angle stretches the spot into an oval
/// - lingering builds up paint until it runs (drips)
/// - pressure drains while you spray and comes back when you shake
final class SprayEngine: ObservableObject {
    enum Phase: Equatable { case idle, aiming, locked, sketching }

    weak var ar: ARController?
    let audio = SprayAudio()
    let haptics = Haptics()
    private let motion = CMMotionManager()

    @Published var phase: Phase = .idle
    @Published var color: String = Theme.paints[0]
    @Published var pressure: Float = 1
    @Published var distance: Float?
    @Published var hint: String?
    @Published var spraying = false
    @Published var draftDabs = 0
    @Published private(set) var wall: WallEntity?

    private(set) var draft = PieceData()
    private var burstStarts: [Int] = []
    private var dripStarts: [Int] = []
    private var trigger = false
    private var density: [Int64: Float] = [:]
    private var dripped = Set<Int64>()
    private var rng = SplitMix(seed: 7)
    private var shakeSign: Float = 0
    private var lastShake: TimeInterval = 0

    // Tuned on paper; adjust after field tests.
    static let minDistance: Float = 0.06
    static let maxDistance: Float = 1.6
    static let lockMin: Float = 1.0
    static let lockMax: Float = 6.5

    init() {
        motion.deviceMotionUpdateInterval = 1.0 / 60
    }

    // MARK: lock-on

    func beginAiming() {
        phase = .aiming
        startShakeDetection()
    }

    /// Locks onto the candidate wall: joins a known wall, or starts a new local one.
    func lock(_ c: WallCandidate) {
        guard let ar else { return }
        let w: WallEntity
        if let existing = c.existing {
            w = existing
        } else {
            let raster = WallRaster(canvasX0: -4, canvasY0: -2, canvasW: 8, canvasH: 6)
            w = WallEntity(id: "local-" + UUID().uuidString, dto: nil, raster: raster, device: ar.device)
            w.localFrame = c.frame
            w.worldFromWall = c.frame
            w.target = c.frame
            w.placed = true
            w.trust = .matched
            ar.view.scene.rootNode.addChildNode(w.canvas.root)
            w.canvas.root.simdWorldTransform = c.frame
            ar.store.addLocal(w)
        }
        wall = w
        draft = PieceData()
        burstStarts = []
        dripStarts = []
        density = [:]
        dripped = []
        draftDabs = 0
        phase = .locked
        haptics.thud()
        hint = c.distance > 2 ? "walk in slowly. hold anywhere to spray" : "hold anywhere to spray"
    }

    /// Same as lock, but for sketch mode: no spraying, the studio takes over.
    @discardableResult
    func lockForSketch(_ c: WallCandidate) -> WallEntity {
        lock(c)
        phase = .sketching
        hint = nil
        return wall!
    }

    func unlock(keepDraft: Bool = false) {
        release()
        if let w = wall {
            w.canvas.hideFootprint()
            if !keepDraft {
                if w.isLocal && w.pieces.isEmpty { ar?.store.remove(w.id) }
                else if !draft.isEmpty { w.rebuildRaster() }
            }
        }
        wall = nil
        draft = PieceData()
        draftDabs = 0
        phase = .aiming
        hint = nil
    }

    func stop() {
        unlock()
        phase = .idle
        motion.stopDeviceMotionUpdates()
    }

    // MARK: trigger

    func press() {
        guard phase == .locked else { return }
        trigger = true
        burstStarts.append(draft.dabs?.count ?? 0)
        dripStarts.append(draft.drips?.count ?? 0)
    }

    func release() {
        trigger = false
        if spraying { spraying = false }
        audio.update(spraying: false, distance: 1, pressure: pressure)
        haptics.spray(false, intensity: 0, sharpness: 0)
    }

    func undoBurst() {
        guard let w = wall, let d = burstStarts.popLast(), let k = dripStarts.popLast() else { return }
        draft.dabs = Array((draft.dabs ?? []).prefix(d))
        draft.drips = Array((draft.drips ?? []).prefix(k))
        draftDabs = draft.dabs?.count ?? 0
        density = [:]
        dripped = []
        w.rebuildRaster(extra: draft)
    }

    /// The unposted paint on a wall, so a background reload doesn't wipe it.
    func liveDraft(for w: WallEntity) -> PieceData? { wall === w && !draft.isEmpty ? draft : nil }

    func takeDraft() -> PieceData { draft }

    func didPost() {
        draft = PieceData()
        burstStarts = []
        dripStarts = []
        draftDabs = 0
    }

    // MARK: per frame

    func tick(frame: ARFrame, dt: Float) {
        guard phase == .locked, let w = wall else {
            if spraying { release() }
            return
        }
        let cam = frame.camera.transform
        let inv = simd_inverse(w.worldFromWall)
        let o4 = inv * SIMD4(cam.position, 1)
        let d4 = inv * SIMD4(-cam.zAxis, 0)
        let o = SIMD3(o4.x, o4.y, o4.z), d = simd_normalize(SIMD3(d4.x, d4.y, d4.z))

        guard d.z < -0.15, o.z > 0 else {
            distance = nil
            w.canvas.hideFootprint()
            hint = "point at the wall"
            if spraying { release() }
            return
        }
        let t = -o.z / d.z
        let hit = SIMD2(o.x + d.x * t, o.y + d.y * t)
        distance = t

        let cosInc = -d.z
        let stretch = min(3, 1 / max(0.33, cosInc))
        let angle = atan2(d.y, d.x)
        let r = 0.008 + 0.085 * t
        let onCanvas = w.canvas.raster.contains(hit.x, hit.y)
        let canSpray = t >= Self.minDistance && t <= Self.maxDistance && onCanvas && frame.camera.trackingState == .normal

        let ui = UIColor(Color(css: color))
        w.canvas.showFootprint(at: hit, radius: r, stretch: stretch, angle: angle, color: ui, strong: canSpray)

        if !onCanvas { hint = "that's past the edge of this wall" }
        else if t < Self.minDistance { hint = "too close. back off a little" }
        else if t > Self.maxDistance { hint = trigger ? "too far. the paint's not reaching" : "walk in closer" }
        else if frame.camera.trackingState != .normal { hint = "slow down, the camera's catching up" }
        else { hint = draftDabs == 0 ? "hold anywhere to spray" : nil }

        let flowing = trigger && canSpray && pressure > 0.01
        if trigger && pressure <= 0.01 { hint = "out of pressure. shake the can" }

        if flowing {
            pressure = max(0, pressure - dt / 14)
            var alpha = min(0.85, 0.019 * dt * 60 / (r * r * 60) * 1.0)
            alpha = max(0.015, alpha)
            if pressure < 0.18 {
                // sputtering: patchy, weaker
                if rng.next() < 0.45 * (1 - pressure / 0.18) { alpha = 0 }
                alpha *= 0.6
            }
            if alpha > 0 {
                var ci = Float(draft.colorIndex(color))
                if draft.dabs == nil { draft.dabs = [] }
                let dab: [Float] = [round4(hit.x), round4(hit.y), round4(r), round4(alpha), round4(stretch), round4(angle), ci]
                draft.dabs!.append(dab)
                draftDabs = draft.dabs!.count
                let col = RGBA8(css: color)
                w.canvas.raster.dab(x: hit.x, y: hit.y, r: r, alpha: alpha, stretch: stretch, angle: angle, color: col)
                accumulate(hit: hit, r: r, alpha: alpha, color: col, ci: &ci, wall: w)
            }
        }

        if flowing != spraying { spraying = flowing }
        audio.update(spraying: flowing, distance: t, pressure: pressure)
        haptics.spray(flowing, intensity: 0.25 + 0.6 * max(0, 1 - t), sharpness: 0.2 + 0.5 * max(0, 1 - t))
    }

    /// Tracks how much paint has built up in 3 cm cells. Too much in one spot starts a run.
    private func accumulate(hit: SIMD2<Float>, r: Float, alpha: Float, color: RGBA8, ci: inout Float, wall w: WallEntity) {
        let cell: Float = 0.03
        let key = Int64(Int32(floor(hit.x / cell))) << 32 | Int64(UInt32(bitPattern: Int32(floor(hit.y / cell))))
        let amount = min(1.5, alpha * (0.03 / max(r, 0.01)) * (0.03 / max(r, 0.01)))
        let v = (density[key] ?? 0) + amount
        density[key] = v
        guard v > 18, !dripped.contains(key), (draft.drips?.count ?? 0) < 60 else { return }
        dripped.insert(key)
        let length = 0.05 + rng.next() * 0.16 + min(0.2, (v - 18) * 0.02)
        let width = max(0.005, min(0.018, r * 0.35))
        let x = hit.x + (rng.next() - 0.5) * r * 0.6
        if draft.drips == nil { draft.drips = [] }
        draft.drips!.append([round4(x), round4(hit.y), round4(length), round4(width), ci])
        w.canvas.raster.drip(x: x, y: hit.y, length: length, width: width, color: color)
    }

    private func round4(_ f: Float) -> Float { (f * 10000).rounded() / 10000 }

    // MARK: shaking

    private func startShakeDetection() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m, !self.trigger else { return }
            let a = m.userAcceleration
            let mag = Float(sqrt(a.x * a.x + a.y * a.y + a.z * a.z))
            guard mag > 1.6 else { return }
            let sign: Float = (a.y + a.x) >= 0 ? 1 : -1
            let now = m.timestamp
            if sign != self.shakeSign && now - self.lastShake > 0.12 {
                self.shakeSign = sign
                self.lastShake = now
                self.audio.rattle()
                self.haptics.tick()
                self.pressure = min(1, self.pressure + 0.07)
            }
        }
    }
}

enum WallFinderMath {
    /// A plane anchor's normal, flipped to face the same way as `facing`.
    static func normal(of plane: ARPlaneAnchor, facing: SIMD3<Float>) -> SIMD3<Float> {
        let n = plane.transform.yAxis
        return simd_dot(n, facing) < 0 ? -n : n
    }
}
