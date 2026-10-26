import AVFoundation
import Foundation
import simd

/// Pinhole model of the frames the capture system actually delivers.
///
/// Focal length comes from the format's own horizontal field of view rather than
/// from the sensor's marketing numbers. Apple's spec sheet says 26 mm equivalent
/// (about 67 degrees horizontal, ~1440 px at 1920 wide), but the 240 fps mode can
/// crop the sensor, and the delivered frame is what the detector measures. The
/// device value is the one that belongs in the model; `fallbackFOVDeg` only
/// covers a format that reports nothing usable.
///
/// Axes are the usual camera convention used by `src/tennisrobot/camera.py`:
/// `x` right, `y` down, `z` forward into the scene, origin at the optical centre.
struct CameraModel: Equatable {
    let width: Int
    let height: Int
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    /// What the model was built from, for the UI and the log.
    let horizontalFOVDeg: Double

    /// Only used if the format reports nonsense. Slightly wide of the ~67 deg a
    /// nominal 26 mm-equivalent wide camera gives, so a wrong fallback biases
    /// depth rather than hiding the problem.
    static let fallbackFOVDeg = 67.0

    init(width: Int, height: Int, horizontalFOVDeg: Double) {
        let w = max(1, width)
        let h = max(1, height)
        self.width = w
        self.height = h
        let fov = (horizontalFOVDeg > 1 && horizontalFOVDeg < 179) ? horizontalFOVDeg : Self.fallbackFOVDeg
        self.horizontalFOVDeg = fov
        // fx = (W/2) / tan(hfov/2); square pixels, so fy = fx.
        self.fx = (Double(w) / 2.0) / tan(fov * Double.pi / 360.0)
        self.fy = self.fx
        self.cx = Double(w) / 2.0
        self.cy = Double(h) / 2.0
    }

    #if os(iOS)
    /// Build from a captured format. `width`/`height` are the delivered buffer
    /// size, which is what the pixel coordinates refer to.
    init(format: AVCaptureDevice.Format, width: Int, height: Int) {
        self.init(width: width, height: height, horizontalFOVDeg: Double(format.videoFieldOfView))
    }
    #endif

    /// Depth of a sphere of radius `ballRadiusM` from its projected radius.
    /// `z = fx * R / r` for a pinhole, which is where all depth in this app
    /// comes from.
    func depth(radiusPx: Double, ballRadiusM: Double) -> Double? {
        guard radiusPx > 0.5, ballRadiusM > 0 else { return nil }
        let z = fx * ballRadiusM / radiusPx
        return z.isFinite ? z : nil
    }

    /// Camera-frame point for a pixel at a known depth.
    func backProject(u: Double, v: Double, depthM: Double) -> SIMD3<Double> {
        let x = (u - cx) / fx
        let y = (v - cy) / fy
        return SIMD3<Double>(x * depthM, y * depthM, depthM)
    }

    /// Pixel position and projected radius of a camera-frame point, or nil when
    /// it is behind the camera.
    func project(_ point: SIMD3<Double>, ballRadiusM: Double) -> (u: Double, v: Double, r: Double)? {
        guard point.z > 1e-3 else { return nil }
        let u = fx * point.x / point.z + cx
        let v = fy * point.y / point.z + cy
        let r = fx * ballRadiusM / point.z
        guard u.isFinite, v.isFinite, r.isFinite else { return nil }
        return (u, v, r)
    }
}

enum CameraGravity {
    /// Gravity expressed in the delivered image frame.
    ///
    /// `CMDeviceMotion.gravity` is in device axes: `+x` right, `+y` up towards
    /// the top of the screen, `+z` out of the screen towards the viewer. The back
    /// camera looks along `-z`, its image `x` is device `+x` and its image `y`
    /// (down) is device `-y`. The capture connection then rotates the delivered
    /// image by the connection's rotation angle about the optical axis, so
    /// gravity is rotated by the same angle to stay in that frame.
    ///
    /// A single camera cannot observe which way is down over a 0.2 s window —
    /// the ball falls centimetres either way — so this is measured, not fitted.
    static func inCameraFrame(
        deviceGravity: SIMD3<Double>,
        rotationAngleDegrees: Double
    ) -> SIMD3<Double> {
        let sensor = SIMD3<Double>(deviceGravity.x, -deviceGravity.y, -deviceGravity.z)
        let radians = rotationAngleDegrees * Double.pi / 180.0
        let c = cos(radians)
        let s = sin(radians)
        return SIMD3<Double>(
            c * sensor.x + s * sensor.y,
            -s * sensor.x + c * sensor.y,
            sensor.z
        )
    }
}
