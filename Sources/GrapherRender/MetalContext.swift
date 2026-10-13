import Foundation
import GrapherKit
import Metal

/// Owns the MTLDevice / command queue shared by every renderer instance.
public final class MetalContext {
    public static let shared = MetalContext()

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.queue = queue
        do {
            self.library = try device.makeLibrary(source: ShaderSource.all, options: nil)
        } catch {
            NSLog("GrapherNG: Metal shader compilation failed: \(error)")
            return nil
        }
    }

    /// Pixel formats the layers are built against.
    ///
    /// `.bgra8Unorm` rather than an `_sRGB` variant: the CPU side computes
    /// coverage in the user's colour space and we do not want the hardware to
    /// apply a transfer function on top of it.
    public static let colorFormat: MTLPixelFormat = .bgra8Unorm

    /// Anti-aliasing is analytic (coverage in the fragment shader), so a single
    /// sample is correct. MSAA would multiply the two coverage estimates and
    /// smear the edges.
    public static let sampleCount = 1
}
