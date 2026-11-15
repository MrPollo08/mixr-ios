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
    /// Palma abierta con (casi) todos los dedos extendidos.
    let openPalm: Bool
    /// Puño cerrado (agarre directo).
    let closedFist: Bool
    /// Centro de la palma en pantalla (punto de agarre).
    let palmCenter: CGPoint
}

/// Detección de manos con Vision (21 articulaciones por mano, hasta 2 manos).
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
    /// Última pose por mano, para no hacer parpadear el esqueleto si Vision
    /// pierde un frame.
    private var lastPoses: [String: HandPose] = [:]
    private var lastSeen: [String: CFTimeInterval] = [:]
    private var lastProcessedAt: CFTimeInterval = 0
    private var busy = false

    init() {
        request.maximumHandCount = 2
    }

    /// Encola un frame. Vision corre en su propia cola y avisa por `completion`.
    func submit(pixelBuffer: CVPixelBuffer,
                viewportSize: CGSize,
                imageAspect: CGFloat,
                orientation: CGImagePropertyOrientation,
                completion: @escaping ([HandPose]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.busy else { return }

            let now = CACurrentMediaTime()
            guard now - self.lastProcessedAt >= Config.handTrackingInterval else { return }
            self.lastProcessedAt = now
            self.busy = true

            let poses = self.detect(pixelBuffer: pixelBuffer,
                                    viewportSize: viewportSize,
                                    imageAspect: imageAspect,
                                    orientation: orientation)
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

    private func detect(pixelBuffer: CVPixelBuffer,
                        viewportSize: CGSize,
                        imageAspect: CGFloat,
                        orientation: CGImagePropertyOrientation) -> [HandPose] {
        do {
            try sequence.perform([request], on: pixelBuffer, orientation: orientation)
        } catch {
            return []
        }

        guard let observations = request.results, !observations.isEmpty else {
            smoothed.removeAll()
            return []
        }

        let projector = ImageProjector(viewportSize: viewportSize, imageAspect: imageAspect)
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
            for (name, point) in raw where point.confidence > 0.15 {
                let mapped = projector.map(CGPoint(x: CGFloat(point.location.x),
                                                   y: CGFloat(point.location.y)))
                joints[name] = smooth(key: key, name: name, value: mapped)
            }
            guard joints.count >= 5 else { continue }
            guard let thumb = joints[.thumbTip], let index = joints[.indexTip] else { continue }

            let pinchPoint = CGPoint(x: (thumb.x + index.x) / 2, y: (thumb.y + index.y) / 2)

            guard let wrist = joints[.wrist], let middle = joints[.middleMCP] else { continue }
            let handSize = hypot(wrist.x - middle.x, wrist.y - middle.y)
            guard handSize > 1 else { continue }

            // Misma fórmula que el port de MediaPipe: 1 = cerrado del todo.
            let ratio = hypot(thumb.x - index.x, thumb.y - index.y) / handSize
            var pinch = min(max(1 - ratio / 0.9, 0), 1)

            // Estándar Quest: la pinza sólo cuenta si el resto de los dedos
            // están relajados (medio, anular y meñique extendidos).
            // Distancia real (la mano mide ~9 cm de muñeca a nudillo).
            let millimeters = ratio * 90
            if !otherFingersRelaxed(joints) || millimeters > 22 {
                pinch = min(pinch, 0.25)
            }

            let openPalm = Self.allFingersExtended(joints)
            let closedFist = Self.isClosedFist(joints)
            let palmCenter = CGPoint(x: (wrist.x + middle.x) / 2, y: (wrist.y + middle.y) / 2)
            poses.append(HandPose(key: key, joints: joints, pinchPoint: pinchPoint,
                                  pinch: pinch, openPalm: openPalm))
                                  pinch: pinch, openPalm: openPalm,
                                  closedFist: closedFist, palmCenter: palmCenter))
        }

        let stale = smoothed.keys.filter { !seen.contains($0) }
        for key in stale { smoothed[key] = nil }

        // Si una mano se perdió hace menos de 0,2 s, se sigue mostrando la
        // última pose: evita el parpadeo del esqueleto y los cortes al arrastrar.
        let now = CACurrentMediaTime()
        for (key, stored) in lastPoses where !seen.contains(key) {
            if now - (lastSeen[key] ?? 0) < 0.2 {
                poses.append(stored)
            }
        }
        for pose in poses where seen.contains(pose.key) {
            lastPoses[pose.key] = pose
            lastSeen[pose.key] = now
        }
        for key in lastPoses.keys where now - (lastSeen[key] ?? 0) > 0.5 {
            lastPoses[key] = nil
            lastSeen[key] = nil
        }

        return poses
    }

    /// Puño cerrado: al menos 3 de los 4 dedos recogidos.
    private static func isClosedFist(_ joints: [VNHumanHandPoseObservation.JointName: CGPoint]) -> Bool {
        guard let wrist = joints[.wrist] else { return false }
        let pairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.indexTip, .indexMCP), (.middleTip, .middleMCP),
            (.ringTip, .ringMCP), (.littleTip, .littleMCP)
        ]
        var curled = 0
        for (tipName, mcpName) in pairs {
            guard let tip = joints[tipName], let mcp = joints[mcpName] else { continue }
            let tipDistance = hypot(tip.x - wrist.x, tip.y - wrist.y)
            let mcpDistance = max(hypot(mcp.x - wrist.x, mcp.y - wrist.y), 1)
            if tipDistance / mcpDistance < 1.12 { curled += 1 }
        }
        return curled >= 3
    }
    /// Mano abierta: al menos 4 de los 5 dedos extendidos.
    private static func allFingersExtended(_ joints: [VNHumanHandPoseObservation.JointName: CGPoint]) -> Bool {
        guard let wrist = joints[.wrist] else { return false }
        let pairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.thumbTip, .thumbCMC), (.indexTip, .indexMCP), (.middleTip, .middleMCP),
            (.ringTip, .ringMCP), (.littleTip, .littleMCP)
        ]
        var extended = 0
        for (tipName, mcpName) in pairs {
            guard let tip = joints[tipName], let mcp = joints[mcpName] else { continue }
            let tipDistance = hypot(tip.x - wrist.x, tip.y - wrist.y)
            let mcpDistance = max(hypot(mcp.x - wrist.x, mcp.y - wrist.y), 1)
            if tipDistance / mcpDistance > 1.25 { extended += 1 }
        }
        return extended >= 4
    }
    /// Verdadero si al menos dos de los tres dedos restantes están extendidos.
    /// Evita clicks fantasma cuando la mano está cerrada.
    private func otherFingersRelaxed(_ joints: [VNHumanHandPoseObservation.JointName: CGPoint]) -> Bool {
        guard let wrist = joints[.wrist] else { return true }

        let pairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.middleTip, .middleMCP),
            (.ringTip, .ringMCP),
            (.littleTip, .littleMCP)
        ]

        var extended = 0
        for (tipName, mcpName) in pairs {
            guard let tip = joints[tipName], let mcp = joints[mcpName] else { continue }
            let tipDistance = hypot(tip.x - wrist.x, tip.y - wrist.y)
            let mcpDistance = max(hypot(mcp.x - wrist.x, mcp.y - wrist.y), 1)
            if tipDistance / mcpDistance > 1.22 { extended += 1 }
        }
        return extended == 3
    }
    /// Suavizado adaptativo (tipo One Euro): cuando la mano está quieta suaviza
    /// fuerte (sin temblor) y cuando se mueve rápido casi no filtra (sin lag).
    private func smooth(key: String,
                        name: VNHumanHandPoseObservation.JointName,
                        value: CGPoint) -> CGPoint {
        var store = smoothed[key] ?? [:]
        guard let previous = store[name] else {
            store[name] = value
            smoothed[key] = store
            return value
        }

        let speed = hypot(value.x - previous.x, value.y - previous.y)
        let alpha = min(0.92, max(0.22, 0.22 + speed * 0.07))

        let result = CGPoint(x: previous.x + (value.x - previous.x) * alpha,
                             y: previous.y + (value.y - previous.y) * alpha)
        store[name] = result
        smoothed[key] = store
        return result
    }
}

/// Pasa puntos normalizados de Vision (imagen ya parada, origen abajo-izquierda)
/// a coordenadas de pantalla con recorte "aspect fill", igual que la cámara.
struct ImageProjector {
    let viewportSize: CGSize
    /// ancho / alto de la imagen ya orientada (4/3 en horizontal, 3/4 en vertical).
    var imageAspect: CGFloat = 3.0 / 4.0

    func map(_ point: CGPoint) -> CGPoint {
        let width = viewportSize.width
        let height = viewportSize.height
        guard width > 1, height > 1, imageAspect > 0.1 else { return .zero }

        let scale = max(width / imageAspect, height)
        let drawnWidth = imageAspect * scale
        let x = (width - drawnWidth) / 2 + point.x * drawnWidth
        let y = (height - scale) / 2 + (1 - point.y) * scale
        return CGPoint(x: x, y: y)
    }
}
