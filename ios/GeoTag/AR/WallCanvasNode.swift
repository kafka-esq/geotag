import Metal
import UIKit
import SceneKit
import simd

/// The visible paint on one wall: a SceneKit plane in the wall's frame, textured straight from a WallRaster.
/// Only the rectangle that changed gets copied to the GPU each frame.
final class WallCanvasNode {
    let root = SCNNode()          // placed at the wall frame (x right, y up, z out of the wall)
    let plane: SCNNode
    private(set) var raster: WallRaster
    private var texture: MTLTexture?
    private let device: MTLDevice?
    let footprint: SCNNode

    init(raster: WallRaster, device: MTLDevice?) {
        self.raster = raster
        self.device = device
        let w = CGFloat(Float(raster.width) / raster.pxPerMetre)
        let h = CGFloat(Float(raster.height) / raster.pxPerMetre)
        let geo = SCNPlane(width: w, height: h)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        geo.materials = [m]
        plane = SCNNode(geometry: geo)
        plane.name = "wall-canvas"
        plane.position = SCNVector3(Float(raster.originX) + Float(w) / 2, Float(raster.originY) + Float(h) / 2, 0.003)
        plane.renderingOrder = 10
        root.addChildNode(plane)

        footprint = WallCanvasNode.makeFootprint()
        footprint.isHidden = true
        root.addChildNode(footprint)

        replace(raster: raster)
    }

    /// Swap in a freshly rendered raster (e.g. after loading pieces in the background).
    func replace(raster newRaster: WallRaster) {
        raster = newRaster
        newRaster.markAll()
        if let device {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                                                             width: newRaster.width, height: newRaster.height,
                                                             mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            texture = device.makeTexture(descriptor: d)
            plane.geometry?.firstMaterial?.diffuse.contents = texture
        }
        let w = CGFloat(Float(newRaster.width) / newRaster.pxPerMetre)
        let h = CGFloat(Float(newRaster.height) / newRaster.pxPerMetre)
        if let p = plane.geometry as? SCNPlane { p.width = w; p.height = h }
        plane.position = SCNVector3(Float(newRaster.originX) + Float(w) / 2, Float(newRaster.originY) + Float(h) / 2, 0.003)
        upload()
    }

    /// Copies whatever changed in the raster to the GPU.
    func upload() {
        guard let texture, let d = raster.takeDirty() else { return }
        let x0 = max(0, d.0), y0 = max(0, d.1), x1 = min(raster.width, d.2), y1 = min(raster.height, d.3)
        guard x1 > x0, y1 > y0 else { return }
        let region = MTLRegionMake2D(x0, y0, x1 - x0, y1 - y0)
        let bpr = raster.width * 4
        raster.pixels.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            texture.replace(region: region, mipmapLevel: 0, withBytes: base + (y0 * bpr + x0 * 4), bytesPerRow: bpr)
        }
    }

    /// Shows where the spray will land: a ring sized to the spray, stretched when you're at an angle.
    func showFootprint(at p: SIMD2<Float>, radius: Float, stretch: Float, angle: Float, color: UIColor, strong: Bool) {
        footprint.isHidden = false
        footprint.simdPosition = SIMD3(p.x, p.y, 0.008)
        footprint.simdOrientation = simd_quatf(angle: angle, axis: SIMD3(0, 0, 1))
        footprint.simdScale = SIMD3(radius * max(1, stretch), radius, 1)
        if let m = footprint.geometry?.firstMaterial {
            m.diffuse.contents = color
            m.transparency = strong ? 0.95 : 0.55
        }
    }

    func hideFootprint() { footprint.isHidden = true }

    private static func makeFootprint() -> SCNNode {
        // unit ring (radius 1) built from a thin tube, lying in the wall plane
        let ring = SCNTorus(ringRadius: 1, pipeRadius: 0.06)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.writesToDepthBuffer = false
        ring.materials = [m]
        let inner = SCNNode(geometry: ring)
        inner.eulerAngles.x = .pi / 2   // torus lies in XZ by default; stand it up in the wall's XY plane
        let outer = SCNNode()
        outer.addChildNode(inner)
        outer.renderingOrder = 20
        let dot = SCNNode(geometry: SCNSphere(radius: 0.08))
        dot.geometry?.firstMaterial = m
        outer.addChildNode(dot)
        return outer
    }
}
