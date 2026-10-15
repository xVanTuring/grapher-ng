import Foundation
import simd

/// 立体图里的点：一个小球。大小按盒内归一化坐标定，随盒子缩放（和图形一起放大缩小）。
enum PointMarker {
    /// 线宽 1 对应的球半径（归一化单位，盒子 = [-1, 1]³）。
    static let radiusPerWidth: Float = 0.007

    static func radius(width: Double) -> Float { radiusPerWidth * Float(max(width, 0.5)) }

    /// 以 `center`（归一化坐标）为心的球，经纬各 `rings` / `segments` 段，法向即半径方向（光滑着色）。
    static func mesh(center: SIMD3<Float>, radius: Float, color: RGBAColor, rings: Int = 10, segments: Int = 16) -> Mesh3D {
        var mesh = Mesh3D(color: color)
        let none = SIMD2<Float>(.nan, .nan)
        for ring in 0...rings {
            let polar = Float.pi * Float(ring) / Float(rings)
            for segment in 0...segments {
                let azimuth = 2 * Float.pi * Float(segment) / Float(segments)
                let normal = SIMD3<Float>(sin(polar) * cos(azimuth), sin(polar) * sin(azimuth), cos(polar))
                mesh.vertices.append(MeshVertex3D(position: center + normal * radius, normal: normal, parameter: none))
            }
        }
        let stride = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for segment in 0..<UInt32(segments) {
                let a = ring * stride + segment
                let b = a + 1
                let c = a + stride
                let d = c + 1
                // 两极那一圈的退化三角形跳过。
                if ring != 0 { mesh.indices.append(contentsOf: [a, c, b]) }
                if ring != UInt32(rings) - 1 { mesh.indices.append(contentsOf: [b, c, d]) }
            }
        }
        return mesh
    }
}

/// 空间曲线末端的箭头：一个小圆锥（归一化坐标，随盒子缩放），大小跟着线宽。
enum ArrowHead {
    /// 线宽 `width`（点）对应的箭头长度（归一化单位）。
    static func length(width: Double) -> Float { min(0.024 * Float(max(width, 1)), 0.1) }

    /// 尖在 `tip`、沿 `direction`（指向尖）的圆锥，底面封口。
    static func mesh(tip: SIMD3<Float>, direction: SIMD3<Float>, length: Float, color: RGBAColor, segments: Int = 18) -> Mesh3D {
        var mesh = Mesh3D(color: color)
        let axis = simd_normalize(direction)
        guard axis.x.isFinite, axis.y.isFinite, axis.z.isFinite else { return mesh }
        let radius = length * 0.36
        let base = tip - axis * length
        // 和轴垂直的两个方向。
        let helper: SIMD3<Float> = abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let e1 = simd_normalize(simd_cross(axis, helper))
        let e2 = simd_cross(axis, e1)
        let none = SIMD2<Float>(.nan, .nan)
        for i in 0...segments {
            let angle = 2 * Float.pi * Float(i) / Float(segments)
            let radial = e1 * cos(angle) + e2 * sin(angle)
            // 侧面法向：半径方向往尖那边斜。
            let normal = simd_normalize(radial * length + axis * radius)
            mesh.vertices.append(MeshVertex3D(position: base + radial * radius, normal: normal, parameter: none))
            mesh.vertices.append(MeshVertex3D(position: tip, normal: normal, parameter: none))
        }
        let capCenter = UInt32(mesh.vertices.count)
        mesh.vertices.append(MeshVertex3D(position: base, normal: -axis, parameter: none))
        for i in 0...segments {
            let angle = 2 * Float.pi * Float(i) / Float(segments)
            let radial = e1 * cos(angle) + e2 * sin(angle)
            mesh.vertices.append(MeshVertex3D(position: base + radial * radius, normal: -axis, parameter: none))
        }
        for i in 0..<UInt32(segments) {
            mesh.indices.append(contentsOf: [2 * i, 2 * i + 2, 2 * i + 1])
            mesh.indices.append(contentsOf: [capCenter, capCenter + 2 + i, capCenter + 1 + i])
        }
        return mesh
    }

    /// 把折线（归一化坐标）末端截掉箭头那一段：线停在圆锥底面，不从尖上戳出来。返回截好的折线与箭头的方向。
    static func trim(_ points: [SIMD3<Float>], length: Float) -> (points: [SIMD3<Float>], direction: SIMD3<Float>)? {
        guard points.count >= 2, let tip = points.last else { return nil }
        var kept = points
        while kept.count >= 2, simd_distance(kept[kept.count - 2], tip) < length { kept.removeLast() }
        let anchor = kept.count >= 2 ? kept[kept.count - 2] : points[points.count - 2]
        let direction = tip - anchor
        guard simd_length(direction) > 1e-6 else { return nil }
        let axis = simd_normalize(direction)
        if kept.count >= 2 { kept[kept.count - 1] = tip - axis * (length * 0.9) } else { kept = [points[0], tip - axis * length * 0.9] }
        return (kept, axis)
    }
}
