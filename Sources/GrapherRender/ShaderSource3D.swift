import Foundation

/// 3D 画布的着色器源码，与 2D 的拼在同一个 library 里编译（`MetalContext`）。
///
/// 坐标约定：顶点是**盒内归一化坐标**（坐标盒 = [-1, 1]³）。几何属于它自己采样时的盒子，
/// `boxTransform` 把它换到当前的盒子（`n' = n × w + xyz`），这样平移、缩放时旧几何也摆得对。
/// 盒外的部分用 6 个 `clip_distance` 平面裁掉：是真正的几何裁剪，边缘照样有 MSAA 抗锯齿。
///
/// `Renderer3D.swift` 里的 `Uniforms3D` / `MeshStyle3D` / `LineInstance3D` 与这里逐字段对应。
enum ShaderSource3D {
    static let all = common + mesh + line

    private static let common = #"""

    struct Uniforms3D {
        float4x4 viewProjection;  // 当前盒子的归一化坐标 → 裁剪空间
        float4   boxTransform;    // xyz 平移，w 缩放
        float4   eye;             // 相机位置（当前盒子的归一化坐标）
        float2   viewportSize;    // 像素
        float    clipToBox;       // 1 = 按坐标盒裁剪；0 = 不裁（盒子自己的棱、盒壁网格）
        float    pad;
    };

    inline float3 placeInBox(float3 p, constant Uniforms3D &u) {
        return p * u.boxTransform.w + u.boxTransform.xyz;
    }
    """#

    /// 曲面：两面打光（看到背面时法向翻过来，颜色压暗一点，内外看得出），网格线按参数坐标画。
    private static let mesh = #"""

    struct MeshVertex3D {
        float3 position;
        float3 normal;
        float2 parameter;
    };

    struct MeshStyle3D {
        float4 color;
    };

    struct MeshOut3D {
        float4 position [[position]];
        float3 normal;
        float3 world;
        float2 parameter;
        float  clip [[clip_distance]] [6];
    };

    struct MeshIn3D {
        float4 position [[position]];
        float3 normal;
        float3 world;
        float2 parameter;
    };

    vertex MeshOut3D mesh3d_vertex(uint vid [[vertex_id]],
                                   const device MeshVertex3D *vertices [[buffer(0)]],
                                   constant Uniforms3D &u [[buffer(1)]])
    {
        MeshVertex3D v = vertices[vid];
        float3 p = placeInBox(v.position, u);
        MeshOut3D out;
        out.position = u.viewProjection * float4(p, 1.0);
        out.normal = v.normal;
        out.world = p;
        out.parameter = v.parameter;
        out.clip[0] = 1.0 - p.x; out.clip[1] = 1.0 + p.x;
        out.clip[2] = 1.0 - p.y; out.clip[3] = 1.0 + p.y;
        out.clip[4] = 1.0 - p.z; out.clip[5] = 1.0 + p.z;
        return out;
    }

    /// 1 像素宽的网格线覆盖率：参数坐标取整数处为线。线太密（一格不到几个像素）时淡出，免得糊成一片。
    inline float gridLine(float p) {
        if (isnan(p)) { return 0.0; }
        float w = fwidth(p);
        float d = abs(fract(p - 0.5) - 0.5) / max(w, 1e-6);
        float fade = clamp(1.5 - w * 4.0, 0.0, 1.0);
        return (1.0 - clamp(d, 0.0, 1.0)) * fade;
    }

    fragment float4 mesh3d_fragment(MeshIn3D in [[stage_in]],
                                    constant MeshStyle3D &style [[buffer(0)]],
                                    constant Uniforms3D &u [[buffer(1)]])
    {
        float3 n = normalize(in.normal);
        float3 toEye = normalize(u.eye.xyz - in.world);
        bool back = dot(n, toEye) < 0.0;
        if (back) { n = -n; }

        // 主光从相机左上方来，再加一盏从相机方向来的补光，环境光托底。
        float3 up = float3(0.0, 0.0, 1.0);
        float3 key = normalize(toEye + up * 0.9 + cross(up, toEye) * 0.5);
        float diffuse = max(dot(n, key), 0.0) * 0.62 + max(dot(n, toEye), 0.0) * 0.22;
        float3 halfway = normalize(key + toEye);
        float specular = pow(max(dot(n, halfway), 0.0), 48.0) * 0.18;

        float3 base = style.color.rgb * (back ? 0.78 : 1.0);
        float3 rgb = base * (0.30 + diffuse) + specular;

        float line = max(gridLine(in.parameter.x), gridLine(in.parameter.y));
        rgb = mix(rgb, rgb * 0.55, line * 0.6);
        return float4(rgb, 1.0);
    }
    """#

    /// 空间曲线、盒子棱线与盒壁网格：每段在屏幕上展开成四边形，片元按到线段的像素距离算覆盖率
    /// （与 2D 描边同一个办法），线宽恒为屏幕像素。深度往相机方向偏一点，贴在曲面上的线不被吃掉。
    private static let line = #"""

    struct LineInstance3D {
        float3 a;
        float3 b;
        float4 color;
        float  halfWidth;
    };

    struct LineOut3D {
        float4 position [[position]];
        float4 color;
        float2 sa;
        float2 sb;
        float  halfWidth;
        float  clip [[clip_distance]] [6];
    };

    struct LineIn3D {
        float4 position [[position]];
        float4 color;
        float2 sa;
        float2 sb;
        float  halfWidth;
    };

    inline float2 toPixels(float4 clip, float2 viewport) {
        float2 ndc = clip.xy / clip.w;
        return float2((ndc.x + 1.0) * 0.5 * viewport.x, (1.0 - ndc.y) * 0.5 * viewport.y);
    }

    vertex LineOut3D line3d_vertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   const device LineInstance3D *lines [[buffer(0)]],
                                   constant Uniforms3D &u [[buffer(1)]])
    {
        LineInstance3D l = lines[iid];
        float3 a = placeInBox(l.a, u);
        float3 b = placeInBox(l.b, u);
        float4 ca = u.viewProjection * float4(a, 1.0);
        float4 cb = u.viewProjection * float4(b, 1.0);
        float2 sa = toPixels(ca, u.viewportSize);
        float2 sb = toPixels(cb, u.viewportSize);

        float2 dir = sb - sa;
        float len = length(dir);
        float2 tangent = len > 1e-4 ? dir / len : float2(1.0, 0.0);
        float2 normal = float2(-tangent.y, tangent.x);
        float extend = l.halfWidth + 1.0;

        bool atEnd = (vid & 1) != 0;
        bool above = (vid & 2) != 0;
        float2 s = (atEnd ? sb : sa) + tangent * (atEnd ? extend : -extend)
                                     + normal * (above ? extend : -extend);
        float4 c = atEnd ? cb : ca;
        float2 ndc = float2(s.x / u.viewportSize.x * 2.0 - 1.0, 1.0 - s.y / u.viewportSize.y * 2.0);

        LineOut3D out;
        out.position = float4(ndc * c.w, max(c.z - 0.002 * c.w, 0.0), c.w);
        out.color = l.color;
        out.sa = sa;
        out.sb = sb;
        out.halfWidth = l.halfWidth;
        float3 p = atEnd ? b : a;
        float on = u.clipToBox;
        out.clip[0] = mix(1.0, 1.0 - p.x, on); out.clip[1] = mix(1.0, 1.0 + p.x, on);
        out.clip[2] = mix(1.0, 1.0 - p.y, on); out.clip[3] = mix(1.0, 1.0 + p.y, on);
        out.clip[4] = mix(1.0, 1.0 - p.z, on); out.clip[5] = mix(1.0, 1.0 + p.z, on);
        return out;
    }

    fragment float4 line3d_fragment(LineIn3D in [[stage_in]])
    {
        float2 p = in.position.xy;
        float2 ab = in.sb - in.sa;
        float len2 = dot(ab, ab);
        float2 ap = p - in.sa;
        float t = len2 > 0.0 ? clamp(dot(ap, ab) / len2, 0.0, 1.0) : 0.0;
        float d = length(ap - ab * t);
        float coverage = clamp(in.halfWidth + 0.5 - d, 0.0, 1.0);
        return float4(in.color.rgb, in.color.a * coverage);
    }
    """#
}
