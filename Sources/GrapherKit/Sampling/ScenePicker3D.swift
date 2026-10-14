import Foundation
import simd

/// 立体图里点一下选中哪个图层：在 CPU 上对场景几何做命中测试，不碰 GPU。
///
/// - 曲面：从相机经点击处发一条射线，对所有三角形求交（Möller–Trumbore），命中点要落在坐标盒里
///   （盒外的部分渲染时被裁掉了，不能点中）。
/// - 曲线：线段投到屏幕上，点击处离线段不超过「半线宽 + 容差」像素算命中。
/// - 先后：曲线只有被**不透明**曲面挡在后面时才让位；半透明曲面挡不住它。贴在曲面上的线（交线、投影）
///   与曲面的深度几乎相等，算曲线在前，免得永远点不中。
public enum ScenePicker3D {

    /// 曲线比曲面深一点点也算在前面（归一化单位）。
    static let lineDepthSlack = 0.03

    /// - Parameters:
    ///   - scene: 内容几何（不含坐标盒线框），按 `source` 的盒子归一化。
    ///   - source: 几何归一化时依据的视图。
    ///   - view: 当前视图（相机、盒子、画布尺寸）。
    ///   - pixel: 点击处，画布像素，左上角原点。
    ///   - tolerance: 曲线的命中容差（像素，加在半线宽之外）。
    /// - Returns: 命中的图层；什么都没点中返回 nil。
    public static func pick(
        _ scene: Scene3D,
        source: View3D,
        view: View3D,
        pixel: SIMD2<Double>,
        tolerance: Double = 5
    ) -> UUID? {
        hit(scene, source: source, view: view, pixel: pixel, tolerance: tolerance)?.layerID
    }

    /// 命中的图层，加上命中点（数据坐标）：悬停读数用。
    public struct Hit: Equatable, Sendable {
        public var layerID: UUID
        public var point: SIMD3<Double>
    }

    public static func hit(
        _ scene: Scene3D,
        source: View3D,
        view: View3D,
        pixel: SIMD2<Double>,
        tolerance: Double = 5
    ) -> Hit? {
        let (scale, translation) = view.boxTransform(from: source)
        let matrix = view.viewProjection()
        let inverse = simd_inverse(matrix)

        // 射线：近、远两个深度上的点连线。
        let ndc = SIMD2(pixel.x / max(view.widthPixels, 1) * 2 - 1, 1 - pixel.y / max(view.heightPixels, 1) * 2)
        func unproject(_ z: Double) -> SIMD3<Double> {
            let p = inverse * SIMD4(ndc.x, ndc.y, z, 1)
            return SIMD3(p.x, p.y, p.z) / p.w
        }
        let origin = unproject(0)
        let direction = simd_normalize(unproject(1) - origin)
        let limit = 1.0005

        func place(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3<Double>(p) * scale + translation }
        func insideBox(_ p: SIMD3<Double>) -> Bool { abs(p.x) <= limit && abs(p.y) <= limit && abs(p.z) <= limit }

        // 曲面：每个图层取最近的命中；记下最近的不透明命中（会挡住曲线）。
        var meshHit: (id: UUID, distance: Double)?
        var opaqueDistance = Double.infinity
        for mesh in scene.meshes {
            guard let id = mesh.layerID else { continue }
            var nearest = Double.infinity
            mesh.indices.withUnsafeBufferPointer { indices in
                for t in stride(from: 0, to: indices.count, by: 3) {
                    let a = place(mesh.vertices[Int(indices[t])].position)
                    let b = place(mesh.vertices[Int(indices[t + 1])].position)
                    let c = place(mesh.vertices[Int(indices[t + 2])].position)
                    guard let distance = rayTriangle(origin, direction, a, b, c), distance < nearest else { continue }
                    if insideBox(origin + direction * distance) { nearest = distance }
                }
            }
            guard nearest.isFinite else { continue }
            if meshHit == nil || nearest < meshHit!.distance { meshHit = (id, nearest) }
            if !mesh.isTranslucent { opaqueDistance = min(opaqueDistance, nearest) }
        }

        // 曲线：屏幕上离点击处最近的那条（同样近取离相机近的）。
        var lineHit: (id: UUID, pixelDistance: Double, depth: Double, point: SIMD3<Double>)?
        func toPixels(_ p: SIMD3<Double>) -> SIMD2<Double>? {
            let clip = matrix * SIMD4(p, 1)
            guard clip.w > 1e-9 else { return nil }
            return SIMD2((clip.x / clip.w + 1) / 2 * view.widthPixels, (1 - clip.y / clip.w) / 2 * view.heightPixels)
        }
        for line in scene.polylines {
            guard let id = line.layerID, line.points.count >= 1 else { continue }
            let reach = line.width / 2 + tolerance
            var previous: (world: SIMD3<Double>, screen: SIMD2<Double>)?
            for point in line.points {
                let world = place(point)
                guard let screen = toPixels(world) else { previous = nil; continue }
                defer { previous = (world, screen) }
                guard let last = previous else { continue }
                let (s, distance) = closestOnSegment(pixel, last.screen, screen)
                guard distance <= reach else { continue }
                let at = last.world + (world - last.world) * s
                guard insideBox(at) else { continue }
                let depth = simd_length(at - origin)
                if let best = lineHit, (distance, depth) >= (best.pixelDistance, best.depth) { continue }
                lineHit = (id, distance, depth, at)
            }
            // 单点的「折线」（极少）不处理。
        }

        func meshResult(_ mesh: (id: UUID, distance: Double)) -> Hit {
            Hit(layerID: mesh.id, point: view.data(origin + direction * mesh.distance))
        }
        func lineResult(_ line: (id: UUID, pixelDistance: Double, depth: Double, point: SIMD3<Double>)) -> Hit {
            Hit(layerID: line.id, point: view.data(line.point))
        }

        switch (meshHit, lineHit) {
        case (nil, nil): return nil
        case (let mesh?, nil): return meshResult(mesh)
        case (nil, let line?): return lineResult(line)
        case (let mesh?, let line?):
            // 被不透明曲面挡住的曲线点不中；其余曲线优先（线细、不容易点，曲面一大片）。
            if opaqueDistance < line.depth - lineDepthSlack { return meshResult(mesh) }
            return lineResult(line)
        }
    }

    /// 射线与三角形的交点距离（沿单位方向），无交点或在射线后面返回 nil。
    static func rayTriangle(
        _ origin: SIMD3<Double>, _ direction: SIMD3<Double>,
        _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>
    ) -> Double? {
        let e1 = b - a
        let e2 = c - a
        let p = simd_cross(direction, e2)
        let determinant = simd_dot(e1, p)
        guard abs(determinant) > 1e-14 else { return nil }
        let inverse = 1 / determinant
        let t = origin - a
        let u = simd_dot(t, p) * inverse
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(t, e1)
        let v = simd_dot(direction, q) * inverse
        guard v >= 0, u + v <= 1 else { return nil }
        let distance = simd_dot(e2, q) * inverse
        return distance > 0 ? distance : nil
    }

    /// 点到线段的最近点参数（0…1）与距离。
    static func closestOnSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> (Double, Double) {
        let ab = b - a
        let length2 = simd_length_squared(ab)
        let s = length2 > 0 ? min(max(simd_dot(p - a, ab) / length2, 0), 1) : 0
        return (s, simd_length(p - (a + ab * s)))
    }
}
