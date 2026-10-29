import ARCore
import Foundation
import simd

/// Posts a finished piece: creates the wall on the server if it's new, then saves the piece in wall coordinates.
enum Poster {
    @MainActor
    static func post(_ data: PieceData, kind: String, on w: WallEntity, ar: ARController) async throws -> PieceDTO {
        let api = SupabaseClient.shared
        var piece = data
        var wallId = w.id

        if w.isLocal {
            guard ar.geoGoodForPosting, let gar = ar.gar else {
                throw APIError(message: "still pinning down where this wall is. look at the buildings around you for a few seconds")
            }
            let geo = try gar.geospatialTransform(transform: w.worldFromWall)
            let q = geo.eastUpSouthQTarget
            let heading = GeoMath.heading(eus: q.act(SIMD3(0, 0, 1)))
            let r = w.canvas.raster
            let created: CreatedWall = try await api.rpc("create_wall", [
                "p_lat": geo.coordinate.latitude, "p_lng": geo.coordinate.longitude, "p_alt": geo.altitude,
                "p_qx": q.imag.x, "p_qy": q.imag.y, "p_qz": q.imag.z, "p_qw": q.real, "p_heading": heading,
                "p_canvas_x0": r.originX, "p_canvas_y0": r.originY,
                "p_canvas_w": Float(r.width) / r.pxPerMetre, "p_canvas_h": Float(r.height) / r.pxPerMetre,
            ])
            let mine = WallPose(lat: geo.coordinate.latitude, lng: geo.coordinate.longitude, alt: geo.altitude, q: q)
            if created.existing {
                // Someone already registered this wall: move our paint into their wall's frame.
                let theirs = try await pose(of: created.id, near: mine)
                piece = transform(piece, from: mine, to: theirs)
                ar.store.remove(w.id)
                ar.store.refreshNow()
            } else {
                ar.store.rename(w, to: created.id)
                w.pose = mine
            }
            wallId = created.id
        }

        let (x0, y0, x1, y1) = piece.bounds
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(piece))
        let made: CreatedPiece = try await api.rpc("add_piece", [
            "p_wall": wallId, "p_kind": kind, "p_data": json,
            "p_x0": x0, "p_y0": y0, "p_x1": x1, "p_y1": y1,
        ])
        let dto = PieceDTO(id: made.id, wall_id: wallId, kind: kind, data: piece, x0: x0, y0: y0, x1: x1, y1: y1,
                           props_count: 0, comment_count: 0, created_at: made.created_at, author_id: nil,
                           handle: nil, i_propped: false, mine: true)
        if let target = ar.store.walls[wallId] {
            target.pieces.append(dto)
            target.piecesLoadedAt = nil
            ar.requestHost(target)
        }
        return dto
    }

    private static func pose(of wallId: String, near p: WallPose) async throws -> WallPose {
        let list: [WallDTO] = try await SupabaseClient.shared.rpc("walls_near", ["p_lat": p.lat, "p_lng": p.lng, "p_radius_m": 30])
        guard let d = list.first(where: { $0.id == wallId }) else { throw APIError(message: "couldn't find that wall") }
        return WallPose(lat: d.lat, lng: d.lng, alt: d.alt, q: simd_quatf(ix: d.qx, iy: d.qy, iz: d.qz, r: d.qw))
    }

    /// Re-expresses every point (and spray direction) of a piece in another wall's frame.
    static func transform(_ p: PieceData, from a: WallPose, to b: WallPose) -> PieceData {
        var out = p
        func cv(_ x: Float, _ y: Float) -> SIMD2<Float> { GeoMath.convert(SIMD2(x, y), from: a, to: b) }
        out.dabs = p.dabs?.map { d in
            guard d.count >= 7 else { return d }
            let c = cv(d[0], d[1])
            let tip = cv(d[0] + cos(d[5]) * 0.01, d[1] + sin(d[5]) * 0.01)
            var n = d
            n[0] = c.x; n[1] = c.y; n[5] = atan2(tip.y - c.y, tip.x - c.x)
            return n
        }
        out.drips = p.drips?.map { d in
            guard d.count >= 5 else { return d }
            let c = cv(d[0], d[1]); var n = d; n[0] = c.x; n[1] = c.y; return n
        }
        out.strokes = p.strokes?.map { s in
            var n = s
            var pts: [Float] = []
            var i = 0
            while i + 1 < s.p.count { let c = cv(s.p[i], s.p[i + 1]); pts += [c.x, c.y]; i += 2 }
            n.p = pts
            return n
        }
        return out
    }
}
