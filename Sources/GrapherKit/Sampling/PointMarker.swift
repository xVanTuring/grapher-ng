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
