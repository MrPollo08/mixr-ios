import CoreVideo
import Foundation
import ImageIO
import UIKit
import Vision

/// Una mano detectada, ya proyectada a coordenadas de pantalla.
struct HandPose {
    /// "L" / "R" / "U0" / "U1": clave estable para el suavizado y el latch del pinch.
    let key: String
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    /// Punto medio entre yema del pulgar e índice.
    let pinchPoint: CGPoint
    /// 0 = mano abierta, 1 = pellizco cerrado.
    let pinch: CGFloat
}

/// Detección de manos con Vision sobre los frames de ARKit.
final class HandTracker {

    /// Conexiones del esqueleto que se dibujan.
    static let connections: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
        [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
    ]

    private let queue = DispatchQueue(label: "mixr.hand-tracker")
    private let request = VNDetectHumanHandPoseRequest()
    private let sequence = VNSequenceRequestHandler()
    private var smoothed: [String: [VNHumanHandPoseObservation.JointName: CGPoint]] = [:]
    private var lastProcessedAt: CFTimeInterval = 0
    private var busy = false

    init() {
        request.maximumHandCount = 2
    }

    /// Encola un frame. Vision corre en su propia cola y avisa por `completion`.
    func submit(pixelBuffer: CVPixelBuffer,
                viewportSize: CGSize,
                completion: @escaping ([HandPose]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.busy else { return }

            let now = CACurrentMediaTime()
            guard now - self.lastProcessedAt >= Config.handTrackingInterval else { return }
            self.lastProcessedAt = now
            self.busy = true

            let poses = self.detect(pixelBuffer: pixelBuffer, viewportSize: viewportSize)
            self.busy = false
            completion(poses)
        }
    }

    func reset() {
        queue.async { [weak self] in
            self?.smoothed.removeAll()
        }
    }

    // MARK: - Detección

    private func detect(pixelBuffer: CVPixelBuffer, viewportSize: CGSize) -> [HandPose] {
        do {
            // .right = cámara trasera en vertical (la app está bloqueada en vertical).
            try sequence.perform([request], on: pixelBuffer, orientation: .right)
        } catch {
            return []
        }

        guard let observations = request.results, !observations.isEmpty else {
            smoothed.removeAll()
            return []
        }

        let projector = ImageProjector(viewportSize: viewportSize)
        var poses: [HandPose] = []
        var seen = Set<String>()

        for observation in observations {
            let key: String
            switch observation.chirality {
            case .left: key = "L"
            case .right: key = "R"
            default: key = "U\(poses.count)"
            }
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            guard let raw = try? observation.recognizedPoints(.all) else { continue }

            var joints: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            for (name, point) in raw where point.confidence > 0.25 {
                let mapped = projector.map(CGPoint(x: CGFloat(point.location.x),
                                                   y: CGFloat(point.location.y)))
                joints[name] = smooth(key: key, name: name, value: mapped)
            }
            guard joints.count >= 6 else { continue }
            guard let thumb = joints[.thumbTip], let index = joints[.indexTip] else { continue }

            let pinchPoint = CGPoint(x: (thumb.x + index.x) / 2, y: (thumb.y + index.y) / 2)

            guard let wrist = joints[.wrist], let middle = joints[.middleMCP] else { continue }
            let handSize = hypot(wrist.x - middle.x, wrist.y - middle.y)
            guard handSize > 1 else { continue }

            // Misma fórmula que el port de MediaPipe: 1 = cerrado del todo.
            let ratio = hypot(thumb.x - index.x, thumb.y - index.y) / handSize
            let pinch = min(max(1 - ratio / 0.9, 0), 1)

            poses.append(HandPose(key: key, joints: joints, pinchPoint: pinchPoint, pinch: pinch))
        }

        let stale = smoothed.keys.filter { !seen.contains($0) }
        for key in stale { smoothed[key] = nil }

        return poses
    }

    /// Suavizado exponencial por articulación (evita el temblor del esqueleto).
    private func smooth(key: String,
                        name: VNHumanHandPoseObservation.JointName,
                        value: CGPoint) -> CGPoint {
        var store = smoothed[key] ?? [:]
        guard let previous = store[name] else {
            store[name] = value
            smoothed[key] = store
            return value
        }
        let alpha: CGFloat = 0.55
        let result = CGPoint(x: previous.x + (value.x - previous.x) * alpha,
                             y: previous.y + (value.y - previous.y) * alpha)
        store[name] = result
        smoothed[key] = store
        return result
    }
}

/// Pasa puntos normalizados de Vision (imagen vertical, origen abajo-izquierda)
/// a coordenadas de pantalla con recorte "aspect fill", igual que la cámara.
struct ImageProjector {
    let viewportSize: CGSize
    /// Relación de aspecto de la imagen vertical de la cámara trasera (4:3).
    var imageAspect: CGFloat = 3.0 / 4.0

    func map(_ point: CGPoint) -> CGPoint {
        let width = viewportSize.width
        let height = viewportSize.height
        guard width > 1, height > 1 else { return .zero }

        let scale = max(width / imageAspect, height)
        let drawnWidth = imageAspect * scale
        let x = (width - drawnWidth) / 2 + point.x * drawnWidth
        let y = (height - scale) / 2 + (1 - point.y) * scale
        return CGPoint(x: x, y: y)
    }
}
