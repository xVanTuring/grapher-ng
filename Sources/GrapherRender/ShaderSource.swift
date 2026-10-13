import Foundation

/// Metal Shading Language source, embedded so the app never has to locate a
/// resource bundle. Compiled once at startup via `device.makeLibrary(source:)`.
///
/// The Swift `LineInstance` / `RectInstance` / `Uniforms` structs in
/// `Renderer2D.swift` must stay layout-compatible with the declarations here.
enum ShaderSource {
    static let all = common + stroke + fill

    private static let common = #"""
    #include <metal_stdlib>
    using namespace metal;

    /// `scale` / `translation` place a prepared scene on screen
    /// (`p' = p * scale + translation`, see `ScreenTransform2D`). Stroke widths
    /// and marker radii are screen pixels and are deliberately left unscaled.
    struct Uniforms {
        float2 viewportSize;
        float2 translation;
        float  scale;
        float  pad;
    };

    inline float2 placed(float2 p, constant Uniforms &uni) {
        return p * uni.scale + uni.translation;
    }

    inline float2 pixelToNDC(float2 p, float2 viewport) {
        return float2(p.x / viewport.x * 2.0 - 1.0,
                      1.0 - p.y / viewport.y * 2.0);
    }
    """#

    /// Strokes and markers share one pipeline: a marker is simply a degenerate
    /// segment, so the same distance-to-segment kernel yields its disc.
    private static let stroke = #"""

    struct Instance {
        float2 a;         // segment start (pixel coordinates, origin top-left)
        float2 b;         // segment end
        float2 tangent;   // unit tangent; (1, 0) when the segment is degenerate
        float  halfWidth; // stroke half width, or marker radius
        float  pad;
        float4 color;     // straight (non-premultiplied) colour
    };

    struct StrokeOut {
        float4 position [[position]];
        float4 color;
        float2 a;
        float2 b;
        float  halfWidth;
    };

    vertex StrokeOut stroke_vertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   const device Instance *instances [[buffer(0)]],
                                   constant Uniforms &uni [[buffer(1)]])
    {
        Instance inst = instances[iid];
        // A uniform positive scale keeps the tangent's direction, so it can be
        // reused as is after placing the end points.
        float2 a = placed(inst.a, uni);
        float2 b = placed(inst.b, uni);
        float2 tangent = inst.tangent;
        float2 normal = float2(-tangent.y, tangent.x);
        // The coverage ramp spans one pixel either side of the true edge.
        float extend = inst.halfWidth + 0.5;

        bool atEnd = (vid & 1) != 0;
        bool above = (vid & 2) != 0;
        float2 anchor = atEnd ? b : a;
        float2 p = anchor + tangent * (atEnd ? extend : -extend)
                          + normal * (above ? extend : -extend);

        StrokeOut out;
        out.position = float4(pixelToNDC(p, uni.viewportSize), 0.0, 1.0);
        out.color = inst.color;
        out.a = a;
        out.b = b;
        out.halfWidth = inst.halfWidth;
        return out;
    }

    fragment float4 stroke_fragment(StrokeOut in [[stage_in]])
    {
        float2 p = in.position.xy;
        float2 ab = in.b - in.a;
        float len2 = dot(ab, ab);
        float2 ap = p - in.a;
        float t = len2 > 0.0 ? clamp(dot(ap, ab) / len2, 0.0, 1.0) : 0.0;
        float d = length(ap - ab * t);
        float coverage = clamp(in.halfWidth + 0.5 - d, 0.0, 1.0);
        return float4(in.color.rgb, in.color.a * coverage);
    }
    """#

    /// Region fills, one instance per rectangle. The sub-pixel area has already
    /// been resolved into `color.a` on the CPU, so no coverage ramp is applied here.
    private static let fill = #"""

    struct RectInstance {
        float4 rect;   // x0, x1, y0, y1 in pixels
        float4 color;
    };

    struct FillOut {
        float4 position [[position]];
        float4 color;
    };

    vertex FillOut fill_vertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               const device RectInstance *rects [[buffer(0)]],
                               constant Uniforms &uni [[buffer(1)]])
    {
        RectInstance r = rects[iid];
        float2 corner = float2((vid & 1) != 0 ? r.rect.y : r.rect.x,
                               (vid & 2) != 0 ? r.rect.w : r.rect.z);
        FillOut out;
        out.position = float4(pixelToNDC(placed(corner, uni), uni.viewportSize), 0.0, 1.0);
        out.color = r.color;
        return out;
    }

    fragment float4 fill_fragment(FillOut in [[stage_in]])
    {
        return in.color;
    }
    """#
}
