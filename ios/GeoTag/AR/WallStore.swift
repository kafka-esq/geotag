import ARCore
import ARKit
import CoreLocation
import SceneKit
import simd

/// How much we trust where a wall is drawn.
enum WallTrust: Int, Comparable {
    case approx = 0     // geospatial only (within a metre or so)
    case matched = 1    // snapped onto a wall plane this phone detected
    case locked = 2     // Cloud Anchor fingerprint matched (centimetres)
    static func < (a: WallTrust, b: WallTrust) -> Bool { a.rawValue < b.rawValue }
}

/// One wall in the world: where it is, how sure we are, and its paint.
final class WallEntity {
    var id: String                    // server id, or "local-…" until the first piece is posted
    var dto: WallDTO?
    var pose: WallPose?               // geospatial pose (server walls, or computed for new ones)
    let canvas: WallCanvasNode
    var pieces: [PieceDTO] = []
    var piecesLoadedAt: Date?
    var loadingPieces = false

    var geoAnchorId: UUID?
    var cloudAnchorId: UUID?
    var cloudId: String?
    var resolvingCloud = false
    var triedCloudIds = Set<String>()

    var worldFromWall = matrix_identity_float4x4
    var target = matrix_identity_float4x4
    var trust: WallTrust = .approx
    var placed = false
    var visible = false
    var observed = false
    var lastSnap: TimeInterval = 0
    var localFrame: simd_float4x4?    // for walls created on this phone this session, the plane we locked on

    var isLocal: Bool { id.hasPrefix("local-") }

    init(id: String, dto: WallDTO?, raster: WallRaster, device: MTLDevice?) {
        self.id = id
        self.dto = dto
        canvas = WallCanvasNode(raster: raster, device: device)
        if let d = dto {
            pose = WallPose(lat: d.lat, lng: d.lng, alt: d.alt, q: simd_quatf(ix: d.qx, iy: d.qy, iz: d.qz, r: d.qw))
        }
    }

    /// Re-renders every piece into a fresh raster off the main thread, then swaps it in.
    func rebuildRaster(extra: PieceData? = nil, done: (() -> Void)? = nil) {
        let old = canvas.raster
        let pieces = self.pieces
        DispatchQueue.global(qos: .userInitiated).async {
            let r = WallRaster(canvasX0: old.originX, canvasY0: old.originY,
                               canvasW: Float(old.width) / old.pxPerMetre, canvasH: Float(old.height) / old.pxPerMetre,
                               pxPerMetre: old.pxPerMetre)
            for p in pieces { r.draw(p.data) }
            if let extra { r.draw(extra) }
            DispatchQueue.main.async {
                self.canvas.replace(raster: r)
                done?()
            }
        }
    }

    /// The topmost piece under a point on the wall.
    func piece(at p: SIMD2<Float>) -> PieceDTO? {
        pieces.reversed().first { p.x >= $0.x0 && p.x <= $0.x1 && p.y >= $0.y0 && p.y <= $0.y1 }
    }
}

/// Keeps the walls around you in sync with the server and pinned in the right place.
final class WallStore {
    weak var ar: ARController?
    private(set) var walls: [String: WallEntity] = [:]
    private var byAnchor: [UUID: String] = [:]
    private var lastFetch: (CLLocationCoordinate2D, Date)?
    private var fetching = false
    private let api = SupabaseClient.shared
    var hostedThisSession = Set<String>()

    var all: [WallEntity] { Array(walls.values) }

    // MARK: fetching

    func maybeFetch(at here: CLLocationCoordinate2D) {
        guard !fetching, api.isConfigured else { return }
        if let (at, when) = lastFetch, GeoMath.distance(at, here) < 35, Date().timeIntervalSince(when) < 30 { return }
        fetching = true
        lastFetch = (here, Date())
        Task {
            defer { Task { @MainActor in self.fetching = false } }
            do {
                let list: [WallDTO] = try await api.rpc("walls_near", ["p_lat": here.latitude, "p_lng": here.longitude, "p_radius_m": 160])
                await MainActor.run { self.merge(list, here: here) }
            } catch {
                await MainActor.run { self.ar?.note("couldn't load walls: \(error.localizedDescription)") }
            }
        }
    }

    func refreshNow() { lastFetch = nil }

    private func merge(_ list: [WallDTO], here: CLLocationCoordinate2D) {
        guard let ar else { return }
        let ids = Set(list.map(\.id))
        for dto in list {
            if let w = walls[dto.id] {
                let countChanged = (w.dto?.piece_count ?? -1) != (dto.piece_count ?? 0)
                w.dto = dto
                if countChanged { w.piecesLoadedAt = nil }
                continue
            }
            let raster = WallRaster(canvasX0: dto.canvas_x0, canvasY0: dto.canvas_y0, canvasW: dto.canvas_w, canvasH: dto.canvas_h)
            let w = WallEntity(id: dto.id, dto: dto, raster: raster, device: ar.device)
            walls[dto.id] = w
            ar.attach(w)
        }
        // drop server walls that fell out of range (keep local, unposted ones)
        for (id, w) in walls where !w.isLocal && !ids.contains(id) {
            if let p = w.pose, GeoMath.distance(.init(latitude: p.lat, longitude: p.lng), here) > 260 { remove(id) }
        }
    }

    func remove(_ id: String) {
        guard let w = walls.removeValue(forKey: id) else { return }
        if let a = w.geoAnchorId { byAnchor[a] = nil }
        if let c = w.cloudAnchorId { byAnchor[c] = nil }
        ar?.detach(w)
    }

    func addLocal(_ w: WallEntity) { walls[w.id] = w }

    /// After posting, a local wall gets its server id.
    func rename(_ w: WallEntity, to id: String) {
        walls[w.id] = nil
        w.id = id
        walls[id] = w
    }

    func register(anchor: UUID, for w: WallEntity) { byAnchor[anchor] = w.id }
    func wall(forAnchor id: UUID) -> WallEntity? { byAnchor[id].flatMap { walls[$0] } }

    // MARK: pieces

    func loadPiecesIfNeeded(_ w: WallEntity, camera: SIMD3<Float>) {
        guard !w.isLocal, !w.loadingPieces, api.isConfigured else { return }
        let d = simd_distance(camera, w.worldFromWall.position)
        let stale = w.piecesLoadedAt.map { Date().timeIntervalSince($0) > (d < 30 ? 45 : 300) } ?? true
        guard d < 90, stale else { return }
        w.loadingPieces = true
        Task {
            do {
                let list: [PieceDTO] = try await api.rpc("wall_pieces", ["p_wall": w.id])
                await MainActor.run {
                    let changed = list.map(\.id) != w.pieces.map(\.id)
                    w.pieces = list
                    w.piecesLoadedAt = Date()
                    w.loadingPieces = false
                    if changed { w.rebuildRaster(extra: self.ar?.spray.liveDraft(for: w)) }
                }
            } catch {
                await MainActor.run { w.loadingPieces = false; w.piecesLoadedAt = Date() }
            }
        }
    }

    // MARK: matching

    /// Finds a known wall that the given locked-on plane belongs to.
    func match(frame f: simd_float4x4) -> WallEntity? {
        var best: (WallEntity, Float)?
        for w in walls.values where w.placed && w.trust >= .approx {
            let wf = w.worldFromWall
            let n = wf.zAxis
            guard simd_dot(n, f.zAxis) > cos(28 * Float.pi / 180) else { continue }
            let rel = simd_inverse(wf) * SIMD4(f.position, 1)
            let r = w.canvas.raster
            let inX = rel.x > r.originX - 0.5 && rel.x < r.originX + Float(r.width) / r.pxPerMetre + 0.5
            let inY = rel.y > r.originY - 0.5 && rel.y < r.originY + Float(r.height) / r.pxPerMetre + 0.5
            guard abs(rel.z) < 0.9, inX, inY else { continue }
            if best == nil || abs(rel.z) < best!.1 { best = (w, abs(rel.z)) }
        }
        return best?.0
    }
}
