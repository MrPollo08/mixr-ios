import ARKit
import CoreMotion
import Foundation
import QuartzCore
import UIKit
import simd

/// Pipeline híbrido **ARKit 6DoF (VIO + LiDAR) + Giroscopio (CoreMotion 100 Hz)**.
///
/// - **ARKit 6DoF** aporta la posición métrica absoluta `(x, y, z)` en los 6 grados
///   de libertad y corrige la deriva gravitacional/visual.
/// - **CoreMotion (Giroscopio + Acelerómetro a 100 Hz)** inyecta el delta rotacional
///   de ultra-baja latencia entre frames de cámara y mantiene 3DoF fluido si ARKit
///   entra en `trackingState = .limited(.excessiveMotion)` en giros rápidos.
final class HybridHeadTracker {

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "mixr.hybrid-gyro"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private let lock = NSLock()
    private var latestGyroQuat: simd_quatf?
    private var gyroAnchorQuat: simd_quatf?
    private var arAnchorRotation: simd_quatf?
    private var lastARKitTimestamp: TimeInterval = 0

    private var lastValidPosition = simd_float3.zero
    private var lastValidRotation = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
    private var hasValidARKitPose = false

    private var positionFilter = OneEuroFilter3D(minCutoffXY: 2.1,
                                                 betaXY: 3.0,
                                                 minCutoffZ: 1.8,
                                                 betaZ: 2.5,
                                                 dCutoff: 1.0)
    private var rotationFilter = OneEuroFilterQuat(minCutoff: 2.8,
                                                   beta: 0.55,
                                                   dCutoff: 1.0)

    var isGyroActive: Bool {
        motionManager.isDeviceMotionActive
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: motionQueue) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }
            let q = simd_normalize(simd_quatf(ix: Float(attitude.quaternion.x),
                                              iy: Float(attitude.quaternion.y),
                                              iz: Float(attitude.quaternion.z),
                                              r: Float(attitude.quaternion.w)))
            self.lock.lock()
            self.latestGyroQuat = q
            if self.gyroAnchorQuat == nil {
                self.gyroAnchorQuat = q
            }
            self.lock.unlock()
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        lock.lock()
        latestGyroQuat = nil
        gyroAnchorQuat = nil
        arAnchorRotation = nil
        hasValidARKitPose = false
        positionFilter.reset()
        rotationFilter.reset()
        lock.unlock()
    }

    func recenterGyro() {
        lock.lock()
        gyroAnchorQuat = latestGyroQuat
        arAnchorRotation = lastValidRotation
        lock.unlock()
    }

    /// Fusiona el `ARCamera` actual con el giroscopio de alta frecuencia.
    func fusedPose(from frame: ARFrame,
                   orientation: UIInterfaceOrientation,
                   viewport: CGSize,
                   imageSize: CGSize) -> CameraPose {
        let now = CACurrentMediaTime()
        let camera = frame.camera
        let rawTransform = camera.transform
        let rawPos = simd_float3(rawTransform.columns.3.x,
                                 rawTransform.columns.3.y,
                                 rawTransform.columns.3.z)
        let rawRot = simd_normalize(simd_quatf(rawTransform))

        let isNormalTracking: Bool
        if case .normal = camera.trackingState {
            isNormalTracking = true
        } else {
            isNormalTracking = false
        }

        lock.lock()
        let currentGyro = latestGyroQuat
        let isNewARFrame = abs(frame.timestamp - lastARKitTimestamp) > 0.0001
        lastARKitTimestamp = frame.timestamp

        var fusedPosition = rawPos
        var fusedDeviceRotation = rawRot

        if isNormalTracking {
            // Tracking 6DoF pleno: actualizamos el ancla del giroscopio con la
            // referencia libre de deriva de ARKit y aplicamos micro-predicción
            // con el delta del giroscopio entre frames.
            if isNewARFrame {
                if let currentGyro, let prevGyro = gyroAnchorQuat {
                    let gyroDelta = simd_normalize(prevGyro.inverse * currentGyro)
                    let predicted = simd_normalize(rawRot * gyroDelta)
                    // Fusión complementaria: 82% ARKit VIO + 18% predicción instantánea de giroscopio.
                    fusedDeviceRotation = simd_normalize(simd_slerp(rawRot, predicted, 0.18))
                }
                gyroAnchorQuat = currentGyro
                arAnchorRotation = rawRot
            } else if let currentGyro, let anchorGyro = gyroAnchorQuat, let anchorAR = arAnchorRotation {
                // Sub-frame entre capturas de cámara: rotación pura de baja latencia del giroscopio.
                let gyroDelta = simd_normalize(anchorGyro.inverse * currentGyro)
                let gyroPredicted = simd_normalize(anchorAR * gyroDelta)
                fusedDeviceRotation = simd_normalize(simd_slerp(rawRot, gyroPredicted, 0.65))
            }

            fusedPosition = positionFilter.filter(rawPos, timestamp: now)
            fusedDeviceRotation = rotationFilter.filter(fusedDeviceRotation, timestamp: now)
            lastValidPosition = fusedPosition
            lastValidRotation = fusedDeviceRotation
            hasValidARKitPose = true
        } else {
            // Tracking limitado (giro brusco o poca luz): la rotación se sostiene
            // con el giroscopio de baja latencia y la traslación se estabiliza con 1€.
            if hasValidARKitPose {
                fusedPosition = positionFilter.filter(rawPos, timestamp: now)
                if let currentGyro, let anchorGyro = gyroAnchorQuat, let anchorAR = arAnchorRotation {
                    let gyroDelta = simd_normalize(anchorGyro.inverse * currentGyro)
                    let gyroRot = simd_normalize(anchorAR * gyroDelta)
                    fusedDeviceRotation = rotationFilter.filter(simsSlerpSafe(rawRot, gyroRot, t: 0.70), timestamp: now)
                } else {
                    fusedDeviceRotation = rotationFilter.filter(rawRot, timestamp: now)
                }
                lastValidPosition = fusedPosition
                lastValidRotation = fusedDeviceRotation
            } else {
                fusedPosition = rawPos
                fusedDeviceRotation = rawRot
            }
        }
        lock.unlock()

        var fusedMatrix = simd_float4x4(fusedDeviceRotation)
        fusedMatrix.columns.3 = simd_float4(fusedPosition.x, fusedPosition.y, fusedPosition.z, 1.0)

        var pose = CameraPose(arkitCamera: camera,
                              fusedDeviceTransform: fusedMatrix,
                              orientation: orientation,
                              viewport: viewport,
                              imageSize: imageSize)
        pose.trackingLimited = !isNormalTracking
        return pose
    }

    private func simsSlerpSafe(_ a: simd_quatf, _ b: simd_quatf, t: Float) -> simd_quatf {
        let alignedB = simd_dot(a.vector, b.vector) < 0 ? simd_quatf(vector: -b.vector) : b
        return simd_normalize(simd_slerp(a, alignedB, t))
    }
}
