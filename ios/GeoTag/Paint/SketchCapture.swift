import CoreImage
import CoreImage.CIFilterBuiltins
import SceneKit
import UIKit
import simd

/// Freeze-and-flatten for sketch mode: snapshot the camera view and unwarp a rectangle of wall into a
/// straight-on picture you can draw on with a finger.
struct SketchFrame {
    var image: CGImage
    var wall: WallEntity
    var x0: Float, y0: Float, width: Float, height: Float   // region in wall metres (x0,y0 = bottom-left)
}

enum SketchCapture {
    static let regionSize = SIMD2<Float>(2.4, 1.8)
    private static let context = CIContext()

    @MainActor
    static func capture(ar: ARController, wall w: WallEntity, center: SIMD2<Float>) -> SketchFrame? {
        let r = w.canvas.raster
        let cw = Float(r.width) / r.pxPerMetre, ch = Float(r.height) / r.pxPerMetre
        let width = min(regionSize.x, cw), height = min(regionSize.y, ch)
        let x0 = min(max(center.x - width / 2, r.originX), r.originX + cw - width)
        let y0 = min(max(center.y - height / 2, r.originY), r.originY + ch - height)

        // hide our own overlays so the snapshot is just the world
        w.canvas.hideFootprint()
        let snap = ar.view.snapshot()
        guard let cg = snap.cgImage else { return nil }
        let scale = CGFloat(cg.width) / max(1, ar.view.bounds.width)
        let h = CGFloat(cg.height)

        func corner(_ x: Float, _ y: Float) -> CGPoint {
            let world = w.worldFromWall * SIMD4(x, y, 0, 1)
            let s = ar.project(SIMD3(world.x, world.y, world.z))
            return CGPoint(x: s.x * scale, y: h - s.y * scale)   // Core Image's origin is bottom-left
        }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = CIImage(cgImage: cg)
        f.topLeft = corner(x0, y0 + height)
        f.topRight = corner(x0 + width, y0 + height)
        f.bottomLeft = corner(x0, y0)
        f.bottomRight = corner(x0 + width, y0)
        guard let out = f.outputImage, let img = context.createCGImage(out, from: out.extent) else { return nil }
        return SketchFrame(image: img, wall: w, x0: x0, y0: y0, width: width, height: height)
    }
}
