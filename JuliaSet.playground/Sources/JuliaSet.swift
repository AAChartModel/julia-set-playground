import UIKit

/// Complex number, where `x` is the real part and `y` is the imaginary part.
public struct Complex {
    public var x = 0.0, y = 0.0
    public init() {}
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// The configuration of a Julia set image.
public struct JuliaSet {
    
    /// The math coordinate that should be located at center of the image.
    public var center = Complex()
    
    /// The horizontal window size (in math coordinate) that should be fit into viewport.
    /// Number `4.0` (from `-2.0` to `+2.0`) should be a proper value to display a Julia set image.
    public var window: Double = 4.0
    
    /// The Julia set constant.
    /// ```
    /// z(n+1) = z(n)^2 + c
    ///                   ^ the constant
    /// ```
    /// See [https://en.wikipedia.org/wiki/Julia_set](https://en.wikipedia.org/wiki/Julia_set).
    public var const = Complex(-0.5, 0.0)
    
    /// The color which is used to render the image.
    public var color = JuliaSetColor(hue: 0, brightness: 0.8)
    
    public init() {}
}

public final class JuliaSetRenderer {
    
    fileprivate static let async_render_queue: DispatchQueue = {
        return DispatchQueue(label: "julia_set_async_render", attributes: DispatchQueue.Attributes.concurrent)
    }()
    
    fileprivate static let sync_render_queue: DispatchQueue = {
        return DispatchQueue(label: "julia_set_sync_render", attributes: DispatchQueue.Attributes.concurrent)
    }()
    
    fileprivate init() {}
    
    /// Generate Julia set image in background, and get the result in main thread.
    public static func asyncRender(_ juliaSet: JuliaSet, sizeInPixel size: CGSize, completion: @escaping (UIImage) -> ()) {
        asyncRender(in: async_render_queue,
                    queueQos: DispatchQoS.QoSClass.background,
                    width: Int(size.width),
                    height: Int(size.height),
                    juliaSet: juliaSet
        ) { cgImage in
            DispatchQueue.main.async {
                completion(UIImage(cgImage: cgImage))
            }
        }
    }
    
    /// Generate Julia set image.
    public static func syncRender(_ juliaSet: JuliaSet, sizeInPixel size: CGSize) -> UIImage {
        var result: UIImage! = nil
        let sema = DispatchSemaphore(value: 0)
        asyncRender(in: sync_render_queue,
                    queueQos: DispatchQoS.QoSClass.userInteractive,
                    width: Int(size.width),
                    height: Int(size.height),
                    juliaSet: juliaSet
        ) { cgImage in
            result = UIImage(cgImage: cgImage)
            sema.signal()
        }
        let _ = sema.wait(timeout: DispatchTime.distantFuture)
        return result
    }
    
    fileprivate static func asyncRender(in renderQueue: DispatchQueue, queueQos: DispatchQoS.QoSClass, width w: Int, height h: Int, juliaSet: JuliaSet, completion: @escaping (CGImage) -> ()) {
        assert(w > 0 && h > 0)
        
        // generate ruler
        let x_values = generateXValues(width: w, height: h, juliaSet: juliaSet)
        let y_values = generateYValues(width: w, height: h, juliaSet: juliaSet)
        
        let wxh = w * h
        let ptr = UnsafeMutablePointer<UInt32>.allocate(capacity: wxh * 4)
        
        let cx = juliaSet.const.x
        let cy = juliaSet.const.y
        let loop = 200 // 200 suits for most situation. Bigger value gives you better quality.
        
        let color = juliaSet.color.toRGBRange()
        let cin = [color.colorIn.0, color.colorIn.1, color.colorIn.2]
        let cout = [color.colorOut.0, color.colorOut.1, color.colorOut.2]
        
        
        DispatchQueue.global(qos: queueQos).async {
            
            // 1. compute pixel by pixel
            
            DispatchQueue.concurrentPerform(iterations: wxh) { index in
                var zx = x_values[index % w]
                var zy = y_values[index / w]
                
                var c = 0.0
                
                // the classical "escape-time" algorithm
                for i in 1..<loop {
                    // z(n+1) = z(n)^2 + c
                    (zx, zy) = (zx * zx - zy * zy + cx, 2.0 * zx * zy + cy)
                    if (zx * zx + zy * zy) > 4.0 {
                        c = Double(i) / Double(loop); // escape-time: 0 to 1
                        break
                    }
                }
                
                // a special coloring algorithm (good tone & contrast)
                var rgb = [0.0, 0.0, 0.0]
                for j in 0..<3 {
                    if cin[j] != cout[j] {
                        rgb[j] = (c - cin[j]) / (cout[j] - cin[j]) * 1.8 // 1.8 makes the image brighter
                    } else {
                        rgb[j] = (c > cin[j]) ? 1.0 : 0.0
                    }
                }
                
                ptr[index] = UInt32(blue: rgb[2], green: rgb[1], red: rgb[0])
            }
            
            // 2. generate image object
            
            let provider = CGDataProvider(dataInfo: nil, data: ptr, size: 4 * wxh) { _, data, size in
                let raw = unsafeBitCast(data, to: UnsafeMutablePointer<UInt32>.self)
                raw.deallocate(capacity: size)
            }
            
            let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * w,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(),
                provider: provider!, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
            )
            
            completion(image!)
        }
    }
    
    static fileprivate func generateXValues(width w: Int, height h: Int, juliaSet: JuliaSet) -> [Double] {
        var arr = [Double]()
        arr.reserveCapacity(w)
        
        let pixel_w = juliaSet.window / Double(w)
        let start_x = (juliaSet.center.x - juliaSet.window / 2.0) + pixel_w / 2.0 // align to center of first pixel
        
        for i in 0..<w {
            arr.append(start_x + Double(i) * pixel_w)
        }
        
        assert(arr.count == w)
        return arr
    }
    
    static fileprivate func generateYValues(width w: Int, height h: Int, juliaSet: JuliaSet) -> [Double] {
        var arr = [Double]()
        arr.reserveCapacity(h)
        
        let window_y = juliaSet.window / Double(w) * Double(h)
        let pixel_h = window_y / Double(h)
        let start_y = (juliaSet.center.y - window_y / 2) + pixel_h / 2 // align to center of first pixel
        
        for i in 0..<h {
            arr.append(start_y + Double(i) * pixel_h)
        }
        
        assert(arr.count == h)
        return arr.reversed() // reverse y-axis
    }
    
}
