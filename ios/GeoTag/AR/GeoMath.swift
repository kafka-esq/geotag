import CoreLocation
import simd

enum GeoMath {
    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0, d = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * d, dLng = (b.longitude - a.longitude) * d
        let h = pow(sin(dLat / 2), 2) + cos(a.latitude * d) * cos(b.latitude * d) * pow(sin(dLng / 2), 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Offset of `b` from `a` in an east-up-south frame, metres. Accurate to millimetres over a city block.
    static func eusOffset(from a: (lat: Double, lng: Double, alt: Double), to b: (lat: Double, lng: Double, alt: Double)) -> SIMD3<Float> {
        let mPerDegLat = 111_132.92 - 559.82 * cos(2 * a.lat * .pi / 180)
        let mPerDegLng = 111_412.84 * cos(a.lat * .pi / 180)
        let east = (b.lng - a.lng) * mPerDegLng
        let north = (b.lat - a.lat) * mPerDegLat
        return SIMD3(Float(east), Float(b.alt - a.alt), Float(-north))
    }

    /// Compass heading (degrees, 0 = north, clockwise) of a direction given in east-up-south space.
    static func heading(eus v: SIMD3<Float>) -> Float {
        let east = v.x, north = -v.z
        var h = atan2(east, north) * 180 / .pi
        if h < 0 { h += 360 }
        return h
    }

    /// Re-expresses a point from one wall's frame in another wall's frame, using their geospatial poses.
    static func convert(_ p: SIMD2<Float>, from a: WallPose, to b: WallPose) -> SIMD2<Float> {
        let inEUS = a.q.act(SIMD3(p.x, p.y, 0))                         // relative to a's origin
        let shift = eusOffset(from: (b.lat, b.lng, b.alt), to: (a.lat, a.lng, a.alt))
        let local = b.q.inverse.act(inEUS + shift)
        return SIMD2(local.x, local.y)
    }
}

/// A wall's geospatial pose: origin plus the rotation from wall frame to east-up-south.
struct WallPose {
    var lat: Double
    var lng: Double
    var alt: Double
    var q: simd_quatf
}

extension simd_float4x4 {
    var position: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
    var xAxis: SIMD3<Float> { simd_normalize(SIMD3(columns.0.x, columns.0.y, columns.0.z)) }
    var yAxis: SIMD3<Float> { simd_normalize(SIMD3(columns.1.x, columns.1.y, columns.1.z)) }
    var zAxis: SIMD3<Float> { simd_normalize(SIMD3(columns.2.x, columns.2.y, columns.2.z)) }

    /// A wall frame: origin p, z = outward normal, y = gravity-up projected onto the wall, x = y × z.
    static func wallFrame(origin p: SIMD3<Float>, normal nIn: SIMD3<Float>) -> simd_float4x4 {
        let n = simd_normalize(nIn)
        var up = SIMD3<Float>(0, 1, 0) - n * simd_dot(SIMD3<Float>(0, 1, 0), n)
        if simd_length(up) < 1e-3 { up = SIMD3(0, 0, -1) }
        up = simd_normalize(up)
        let x = simd_normalize(simd_cross(up, n))
        return simd_float4x4(columns: (SIMD4(x, 0), SIMD4(up, 0), SIMD4(n, 0), SIMD4(p, 1)))
    }

    /// Blend toward another rigid transform: lerp position, slerp rotation.
    func blended(toward t: simd_float4x4, _ k: Float) -> simd_float4x4 {
        let qa = simd_quatf(self), qb = simd_quatf(t)
        let q = simd_slerp(qa, qb, k)
        let p = simd_mix(position, t.position, SIMD3(repeating: k))
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4(p, 1)
        return m
    }
}
