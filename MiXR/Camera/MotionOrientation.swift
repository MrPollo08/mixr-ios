import CoreMotion
import Foundation
import simd

/// Orientación del teléfono con CoreMotion (3DoF).
///
/// Es lo que reemplaza a ARKit cuando usamos la cámara 0.5x: no hay traslación,
/// pero la rotación alcanza para que las ventanas queden "pegadas" al mundo
/// cuando mirás para otro lado, que es el efecto tipo Quest.
final class MotionOrientation {

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "mixr.motion"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let lock = NSLock()
    private var origin: simd_quatf?
    private var relative = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isRunning: Bool { manager.isDeviceMotionActive }

    /// Rotación del teléfono respecto de la posición en que arrancó (o del
    /// último recentrado).
    var rotation: simd_quatf {
        lock.lock(); defer { lock.unlock() }
        return relative
    }

    var transform: simd_float4x4 {
        simd_float4x4(rotation)
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }

        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }

            let q = simd_quatf(ix: Float(attitude.quaternion.x),
                               iy: Float(attitude.quaternion.y),
                               iz: Float(attitude.quaternion.z),
                               r: Float(attitude.quaternion.w))

            self.lock.lock()
            if self.origin == nil { self.origin = q }
            if let origin = self.origin {
                self.relative = simd_normalize(q * origin.inverse)
            }
            self.lock.unlock()
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock()
        origin = nil
        relative = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        lock.unlock()
    }

    /// Toma la orientación actual como "adelante".
    func recenter() {
        lock.lock()
        origin = nil
        lock.unlock()
    }
}
