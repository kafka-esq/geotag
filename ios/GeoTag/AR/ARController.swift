import ARCore
import ARKit
import CoreLocation
import SceneKit
import SwiftUI
import simd

/// Where we are in finding our place in the world.
enum LocState: Equatable {
    case starting(String)
    case localizing(String)
    case ready
    case failed(String)
}

/// What the crosshair is pointing at, and whether it's good enough to paint on.
struct WallCandidate {
    var frame: simd_float4x4       // wall frame at the hit point
    var distance: Float
    var size: SIMD2<Float>?        // detected width, height in metres
    var problems: [String]
    var existing: WallEntity?
    var plane: ARPlaneAnchor?
    var ok: Bool { problems.isEmpty }
}

/// Owns the AR camera, ARCore's Geospatial session, and the per-frame loop that keeps walls in place.
final class ARController: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate, CLLocationManagerDelegate {
    let view = ARSCNView(frame: .zero)
    let store = WallStore()
    let spray: SprayEngine
    let device: MTLDevice?

    @Published var loc: LocState = .starting("starting the camera")
    @Published var accuracy: Double?
    @Published var yawAccuracy: Double?
    @Published var candidate: WallCandidate?
    @Published var vpsAvailable: Bool?
    @Published var toast: String?
    @Published var hasLiDAR = false

    var practice = false
    private(set) var gar: GARSession?
    private var location = CLLocationManager()
    private var lastCoordinate: CLLocationCoordinate2D?
    private var started = false
    private var tokenTimer: Timer?
    private var lastFrameTime: TimeInterval = 0
    private var lastCandidateCheck: TimeInterval = 0
    private var hosting: (wall: WallEntity, anchor: ARAnchor, started: Date)?
    private var hostFuture: GARHostCloudAnchorFuture?
    private var resolveFutures: [String: GARResolveCloudAnchorFuture] = [:]
    private var semanticsOn = false
    private var lastGeo: GARGeospatialTransform?

    var coordinate: CLLocationCoordinate2D? {
        if let g = lastGeo { return g.coordinate }
        return lastCoordinate
    }

    /// True when the geospatial fix is good enough to show and post art.
    var geoReady: Bool { if case .ready = loc { return true }; return false }

    var geoGoodForPosting: Bool {
        guard geoReady, let a = accuracy, let y = yawAccuracy else { return false }
        return a <= 3 && y <= 10
    }

    override init() {
        device = MTLCreateSystemDefaultDevice()
        spray = SprayEngine()
        super.init()
        store.ar = self
        spray.ar = self
        view.delegate = self
        view.session.delegate = self
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        hasLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    // MARK: lifecycle

    func start(practice: Bool) {
        self.practice = practice
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity                 // Geospatial needs gravity alignment
        config.planeDetection = [.vertical, .horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.isAutoFocusEnabled = true
        view.session.run(config, options: started ? [] : [.resetTracking, .removeExistingAnchors])
        spray.audio.start()
        guard !started else { return }
        started = true
        if practice {
            loc = .ready
            return
        }
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        default: locationManagerDidChangeAuthorization(location)
        }
    }

    func pause() {
        view.session.pause()
        spray.audio.stop()
    }

    func note(_ s: String) { toast = s }

    // MARK: ARCore session

    private func setUpGeospatial() {
        guard gar == nil else { return }
        do {
            let session: GARSession
            if Secrets.arcoreTokenAuth {
                session = try GARSession.session()
            } else {
                guard !Secrets.arcoreAPIKey.isEmpty else {
                    loc = .failed("the arcore api key isn't set. see README step 2")
                    return
                }
                session = try GARSession(apiKey: Secrets.arcoreAPIKey, bundleIdentifier: nil)
            }
            guard session.isGeospatialModeSupported(.enabled) else {
                loc = .failed("this iphone can't do geospatial ar. try practice mode")
                return
            }
            let config = GARSessionConfiguration()
            config.geospatialMode = .enabled
            config.streetscapeGeometryMode = .enabled
            config.cloudAnchorMode = .enabled
            if session.isSemanticModeSupported(.enabled) {
                config.semanticMode = .enabled
                semanticsOn = true
            }
            var error: NSError?
            session.setConfiguration(config, error: &error)
            if let error {
                loc = .failed("arcore setup failed (\(error.code))")
                return
            }
            gar = session
            loc = .localizing("point at buildings across the street")
            if Secrets.arcoreTokenAuth { refreshToken() }
        } catch let e as NSError {
            loc = .failed("arcore couldn't start (\(e.code))")
        }
    }

    /// With token auth, ARCore needs a fresh signed token every hour (backend/functions/arcore-token).
    private func refreshToken() {
        Task {
            do {
                let obj = try await SupabaseClient.shared.function("arcore-token")
                if let t = obj["token"] as? String {
                    await MainActor.run { self.gar?.setAuthToken(t.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
            } catch {
                await MainActor.run { self.note("couldn't get an arcore token: \(error.localizedDescription)") }
            }
        }
        tokenTimer?.invalidate()
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 50 * 60, repeats: false) { [weak self] _ in self?.refreshToken() }
    }

    // MARK: location permission

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if manager.accuracyAuthorization != .fullAccuracy {
                loc = .failed("geo# needs precise location. turn it on in settings")
                return
            }
            manager.startUpdatingLocation()
            setUpGeospatial()
        case .denied, .restricted:
            loc = .failed("geo# needs location to find walls. turn it on in settings")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let first = lastCoordinate == nil
        lastCoordinate = l.coordinate
        if first, let gar {
            gar.checkVPSAvailability(coordinate: l.coordinate) { [weak self] availability in
                DispatchQueue.main.async { self?.vpsAvailable = availability == .available }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: the frame loop

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        let dt = lastFrameTime == 0 ? 1.0 / 60 : min(0.1, now - lastFrameTime)
        lastFrameTime = now

        var garFrame: GARFrame?
        if let gar, !practice {
            garFrame = try? gar.update(frame)
            if let g = garFrame { updateLocalization(g) }
        }

        if let g = garFrame { placeWalls(g, frame: frame) }
        for w in store.all { w.canvas.upload() }

        if now - lastCandidateCheck > 0.12 {
            lastCandidateCheck = now
            candidate = findWall(frame: frame, garFrame: garFrame)
        }

        spray.tick(frame: frame, dt: Float(dt))
        if let g = garFrame { tickHosting(frame: frame, garFrame: g) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        loc = .failed("the camera stopped: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) { spray.release() }

    private func updateLocalization(_ g: GARFrame) {
        guard let earth = g.earth else { return }
        if earth.earthState != .enabled {
            switch earth.earthState {
            case .errorNotAuthorized: loc = .failed("arcore says the api key isn't allowed. check README step 2")
            case .errorResourceExhausted: loc = .failed("arcore quota is used up for now")
            default: loc = .localizing("starting geospatial")
            }
            return
        }
        guard earth.trackingState == .tracking, let t = earth.cameraGeospatialTransform else {
            loc = .localizing("move your phone slowly")
            return
        }
        lastGeo = t
        accuracy = t.horizontalAccuracy
        yawAccuracy = t.orientationYawAccuracy
        let good = t.horizontalAccuracy < 10 && t.orientationYawAccuracy < 15
        if good {
            if loc != .ready { loc = .ready; spray.haptics.tick() }
            store.maybeFetch(at: t.coordinate)
        } else if loc == .ready && (t.horizontalAccuracy > 20 || t.orientationYawAccuracy > 25) {
            loc = .localizing("lost the lock. look at buildings again")
        } else if loc != .ready {
            loc = .localizing(vpsAvailable == false
                              ? "no street view here. it'll be rough"
                              : "point at buildings and signs across the street")
        }
    }

    // MARK: walls in the world

    func attach(_ w: WallEntity) {
        view.scene.rootNode.addChildNode(w.canvas.root)
        w.canvas.root.isHidden = true
        guard let gar, let p = w.pose else { return }
        if let a = try? gar.createAnchor(coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng),
                                         altitude: p.alt, eastUpSouthQAnchor: p.q) {
            w.geoAnchorId = a.identifier
            store.register(anchor: a.identifier, for: w)
        }
    }

    func detach(_ w: WallEntity) {
        w.canvas.root.removeFromParentNode()
    }

    /// Positions every wall: cloud anchor if resolved, otherwise geospatial anchor snapped onto a detected plane.
    private func placeWalls(_ g: GARFrame, frame: ARFrame) {
        let cam = frame.camera.transform.position
        let ready = geoReady
        var poses: [UUID: simd_float4x4] = [:]
        for a in g.anchors where a.trackingState == .tracking { poses[a.identifier] = a.transform }
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .vertical }

        for w in store.all {
            if let lf = w.localFrame { w.target = lf; w.trust = .matched }
            else if let c = w.cloudAnchorId, let t = poses[c] { w.target = t; w.trust = .locked }
            else if let gId = w.geoAnchorId, let base = poses[gId] {
                if frame.timestamp - w.lastSnap > 0.4 {
                    w.lastSnap = frame.timestamp
                    let (snapped, info) = snap(base, planes: planes)
                    w.target = snapped
                    w.trust = info.matched ? .matched : .approx
                    if !w.observed, ready, let acc = accuracy, acc < 2.5, info.considered {
                        w.observed = true
                        let wid = w.id
                        Task { try? await SupabaseClient.shared.rpcVoid("observe_wall", [
                            "p_wall": wid, "p_offset_m": info.offset, "p_angle_deg": info.angle, "p_matched": info.matched]) }
                    }
                }
            } else { continue }

            let visibleNow = w.trust >= .matched || (ready && !w.isLocal)
            if !w.placed { w.worldFromWall = w.target; w.placed = true }
            else { w.worldFromWall = w.worldFromWall.blended(toward: w.target, w.trust == .locked ? 0.35 : 0.12) }
            w.canvas.root.simdWorldTransform = w.worldFromWall
            w.canvas.root.isHidden = !visibleNow
            w.visible = visibleNow

            store.loadPiecesIfNeeded(w, camera: cam)
            maybeResolveCloud(w, camera: cam)
        }
    }

    private struct SnapInfo { var matched: Bool; var considered: Bool; var offset: Float; var angle: Float }

    /// Moves a geospatially placed wall flush onto the wall plane ARKit sees, if there's one close enough.
    private func snap(_ base: simd_float4x4, planes: [ARPlaneAnchor]) -> (simd_float4x4, SnapInfo) {
        let n0 = base.zAxis, p0 = base.position
        var best: (simd_float4x4, Float, Float)?
        var nearestMiss: (Float, Float)?
        for plane in planes {
            var n = plane.transform.yAxis
            if simd_dot(n, n0) < 0 { n = -n }
            let angle = acos(max(-1, min(1, simd_dot(n, n0)))) * 180 / .pi
            let center = (plane.transform * SIMD4(plane.center, 1))
            let off = simd_dot(p0 - SIMD3(center.x, center.y, center.z), n)
            // only consider planes near the stored spot (lateral distance)
            let lateral = simd_length((p0 - n * off) - SIMD3(center.x, center.y, center.z))
            let reach = max(plane.planeExtent.width, plane.planeExtent.height) / 2 + 1.2
            guard lateral < reach else { continue }
            if angle < 30 && abs(off) < 1.0 {
                if best == nil || abs(off) < best!.1 {
                    best = (simd_float4x4.wallFrame(origin: p0 - n * off, normal: n), abs(off), angle)
                }
            } else if lateral < 2 {
                nearestMiss = (off, angle)
            }
        }
        if let b = best { return (b.0, SnapInfo(matched: true, considered: true, offset: b.1, angle: b.2)) }
        if let m = nearestMiss { return (base, SnapInfo(matched: false, considered: true, offset: m.0, angle: m.1)) }
        return (base, SnapInfo(matched: false, considered: false, offset: 0, angle: 0))
    }

    // MARK: finding a wall to paint

    private func findWall(frame: ARFrame, garFrame: GARFrame?) -> WallCandidate? {
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard view.bounds.width > 0 else { return nil }
        var hitFrame: simd_float4x4?
        var plane: ARPlaneAnchor?
        if let q = view.raycastQuery(from: center, allowing: .existingPlaneGeometry, alignment: .vertical),
           let r = view.session.raycast(q).first {
            plane = r.anchor as? ARPlaneAnchor
            var n = plane?.transform.yAxis ?? r.worldTransform.yAxis
            let p = r.worldTransform.position
            if simd_dot(n, frame.camera.transform.position - p) < 0 { n = -n }
            hitFrame = .wallFrame(origin: p, normal: n)
        } else if let q = view.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .vertical),
                  let r = view.session.raycast(q).first {
            var n = r.worldTransform.yAxis
            let p = r.worldTransform.position
            if simd_dot(n, frame.camera.transform.position - p) < 0 { n = -n }
            hitFrame = .wallFrame(origin: p, normal: n)
        }
        guard let f = hitFrame else { return nil }

        let camPos = frame.camera.transform.position
        let distance = simd_distance(camPos, f.position)
        var problems: [String] = []
        let size = plane.map { SIMD2($0.planeExtent.width, $0.planeExtent.height) }
        let n = f.zAxis
        if abs(n.y) > 0.25 { problems.append("not vertical") }
        if plane == nil { problems.append("still measuring this wall") }
        if let s = size, s.x < 1.2 || s.y < 0.9 { problems.append("wall too small (\(String(format: "%.1f×%.1f", s.x, s.y)) m)") }
        if let flat = flatness(frame: frame, wall: f), flat > 0.035 { problems.append("surface isn't flat") }
        if semanticsOn, let g = garFrame, let label = centerLabel(g), ![GARSemanticLabel.building, .structure].contains(label) {
            problems.append(label == .vehicle ? "that's a vehicle" : label == .tree ? "that's a tree" : label == .person ? "that's a person" : "doesn't look like a building")
        }
        let existing = store.match(frame: f)
        return WallCandidate(frame: f, distance: distance, size: size, problems: problems, existing: existing, plane: plane)
    }

    /// RMS distance of LiDAR depth points from the wall plane, in metres. Nil without LiDAR.
    private func flatness(frame: ARFrame, wall: simd_float4x4) -> Float? {
        guard let depth = frame.sceneDepth?.depthMap else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        let img = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let sx = Float(w) / Float(img.width), sy = Float(h) / Float(img.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy, cx = k[2][0] * sx, cy = k[2][1] * sy
        let camT = frame.camera.transform
        let inv = simd_inverse(wall)
        var sum: Float = 0, count: Float = 0
        for gy in 0..<9 {
            for gx in 0..<9 {
                let u = Int(Float(w) * (0.35 + 0.3 * Float(gx) / 8))
                let v = Int(Float(h) * (0.35 + 0.3 * Float(gy) / 8))
                let d = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float32.self)[u]
                guard d > 0.1, d < 8 else { continue }
                let pc = SIMD4<Float>((Float(u) - cx) / fx * d, -(Float(v) - cy) / fy * d, -d, 1)
                let pw = camT * pc
                let local = inv * pw
                sum += local.z * local.z
                count += 1
            }
        }
        return count > 20 ? sqrt(sum / count) : nil
    }

    private func centerLabel(_ g: GARFrame) -> GARSemanticLabel? {
        guard let buf = g.semanticImage else { return nil }
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buf)
        var counts: [UInt8: Int] = [:]
        for dy in -2...2 {
            for dx in -2...2 {
                let x = w / 2 + dx * max(1, w / 40), y = h / 2 + dy * max(1, h / 40)
                let v = base.advanced(by: y * row + x).assumingMemoryBound(to: UInt8.self).pointee
                counts[v, default: 0] += 1
            }
        }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return GARSemanticLabel(rawValue: Int(top))
    }

    // MARK: cloud anchors

    private func maybeResolveCloud(_ w: WallEntity, camera: SIMD3<Float>) {
        guard Secrets.arcoreTokenAuth, let gar, w.cloudAnchorId == nil, !w.resolvingCloud,
              resolveFutures.count < 2, let ids = w.dto?.anchors,
              simd_distance(camera, w.worldFromWall.position) < 25,
              let next = ids.first(where: { !w.triedCloudIds.contains($0) }) else { return }
        w.resolvingCloud = true
        w.triedCloudIds.insert(next)
        do {
            resolveFutures[next] = try gar.resolveCloudAnchor(next) { [weak self, weak w] anchor, state in
                DispatchQueue.main.async {
                    guard let self, let w else { return }
                    self.resolveFutures[next] = nil
                    w.resolvingCloud = false
                    let ok = state == .success && anchor != nil
                    if ok, let anchor {
                        w.cloudAnchorId = anchor.identifier
                        w.cloudId = next
                        self.store.register(anchor: anchor.identifier, for: w)
                    }
                    Task { try? await SupabaseClient.shared.rpcVoid("anchor_result", ["p_cloud_id": next, "p_ok": ok]) }
                }
            }
        } catch {
            w.resolvingCloud = false
        }
    }

    /// Saves a visual fingerprint for a wall so other phones can lock onto it to the centimetre.
    func requestHost(_ w: WallEntity) {
        guard Secrets.arcoreTokenAuth, hosting == nil, !w.isLocal, !store.hostedThisSession.contains(w.id),
              (w.dto?.anchors?.count ?? 0) < 3 else { return }
        let a = ARAnchor(name: "geo-host", transform: w.worldFromWall)
        view.session.add(anchor: a)
        hosting = (w, a, Date())
    }

    private func tickHosting(frame: ARFrame, garFrame: GARFrame) {
        guard let h = hosting, hostFuture == nil, let gar else { return }
        if Date().timeIntervalSince(h.started) > 60 { view.session.remove(anchor: h.anchor); hosting = nil; return }
        let q = (try? gar.estimateFeatureMapQualityForHosting(frame.camera.transform)) ?? .insufficient
        guard q != .insufficient else { return }
        let wallId = h.wall.id
        do {
            hostFuture = try gar.hostCloudAnchor(h.anchor, ttlDays: 365) { [weak self] cloudId, state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hostFuture = nil
                    if let h = self.hosting { self.view.session.remove(anchor: h.anchor) }
                    self.hosting = nil
                    self.store.hostedThisSession.insert(wallId)
                    guard state == .success, let cloudId else { return }
                    Task { try? await SupabaseClient.shared.rpcVoid("add_wall_anchor", ["p_wall": wallId, "p_cloud_id": cloudId, "p_ttl_days": 365]) }
                }
            }
        } catch {
            view.session.remove(anchor: h.anchor)
            hosting = nil
        }
    }

    // MARK: picking art

    /// The wall and the point on it under a screen tap.
    func pick(_ point: CGPoint) -> (WallEntity, SIMD2<Float>)? {
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        for h in hits where h.node.name == "wall-canvas" {
            guard let w = store.all.first(where: { $0.canvas.plane === h.node }) else { continue }
            let local = w.canvas.root.simdConvertPosition(h.simdWorldCoordinates, from: nil)
            return (w, SIMD2(local.x, local.y))
        }
        return nil
    }

    /// Screen position of a point in world space.
    func project(_ p: SIMD3<Float>) -> CGPoint {
        let v = view.projectPoint(SCNVector3(p.x, p.y, p.z))
        return CGPoint(x: CGFloat(v.x), y: CGFloat(v.y))
    }
}
