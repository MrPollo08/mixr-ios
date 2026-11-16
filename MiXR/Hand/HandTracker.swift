import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import UIKit
import Vision
import simd

/// Definición de un hueso anatómico para skinning de la malla low-poly 3D de la mano.
struct HandBoneDefinition {
    let parent: VNHumanHandPoseObservation.JointName
    let child: VNHumanHandPoseObservation.JointName
    /// 0 = pulgar, 1 = índice, 2 = medio, 3 = anular, 4 = meñique.
    let fingerIndex: Int
    /// 0 = metacarpiano/proximal, 1 = intermedio, 2 = distal, 3 = punta.
    let segmentIndex: Int
    /// Radio inicial y final respecto del tamaño de palma (`hypot(wrist - middleMCP)`).
    let radiusStartRatio: CGFloat
    let radiusEndRatio: CGFloat
}

/// Estado de un hueso 3D ya transformado y suavizado con One-Euro.
struct HandBonePose3D {
    let definition: HandBoneDefinition
    let start2D: CGPoint
    let end2D: CGPoint
    let startCamera3D: simd_float3
    let endCamera3D: simd_float3
    let rotation3D: simd_quatf
    /// Distancia media a la cámara (metros, menor = más cerca del visor).
    let depthMeters: Float
}

/// Una mano detectada por Vision + LiDAR, suavizada con el filtro One-Euro en 2D y 3D.
struct HandPose {
    /// "L" / "R" / "U0" / "U1": clave estable para los bancos de filtros One-Euro.
    let key: String
    /// Articulaciones 2D en coordenadas del viewport (suavizadas con One-Euro 2D).
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    /// Articulaciones 3D en el marco local de la cámara en metros reales (suavizadas con One-Euro 3D).
    let jointsCamera3D: [VNHumanHandPoseObservation.JointName: simd_float3]
    /// Articulaciones 3D en el espacio del mundo ARKit en metros reales.
    let jointsWorld3D: [VNHumanHandPoseObservation.JointName: simd_float3]
    /// Profundidad métrica individual de cada articulación (metros).
    let jointDepths: [VNHumanHandPoseObservation.JointName: Float]
    /// Huesos 3D calculados para deformar la malla low-poly de la mano.
    let bones3D: [HandBonePose3D]
    /// Distancia real a la palma en metros (LiDAR + filtro One-Euro).
    let depthMeters: Float
    /// Indica si la profundidad proviene del sensor LiDAR (`sceneDepth`).
    let hasLiDAR: Bool
    /// Punto medio entre yema del pulgar e índice.
    let pinchPoint: CGPoint
    /// Posición 3D en el mundo del punto de pinza.
    let pinchWorld3D: simd_float3
    /// 0 = mano abierta, 1 = pellizco cerrado.
    let pinch: CGFloat
    /// Palma abierta con dedos extendidos.
    let openPalm: Bool
    /// Puño cerrado.
    let closedFist: Bool
    /// Centro de la palma en pantalla.
    let palmCenter: CGPoint
    /// Normal 3D de la palma en el espacio de la cámara.
    let palmNormalCamera3D: simd_float3
    /// Confianza mínima de los puntos clave (0…1).
    let confidence: CGFloat

    /// Reproyecta las 21 coordenadas 3D del mundo (`jointsWorld3D`) a la cámara de un ojo
    /// específico (`leftEyePose` / `rightEyePose`) para lograr disparidad estereoscópica
    /// real de la malla 3D de la mano en la caja VR.
    func projected(for eyePose: CameraPose) -> HandPose {
        guard !jointsWorld3D.isEmpty else { return self }

        var eyeJoints2D: [VNHumanHandPoseObservation.JointName: CGPoint] = joints
        var eyeCamera3D: [VNHumanHandPoseObservation.JointName: simd_float3] = jointsCamera3D
        var eyeDepths: [VNHumanHandPoseObservation.JointName: Float] = jointDepths

        for (name, worldPt) in jointsWorld3D {
            let camPt = eyePose.worldToCamera(worldPt)
            eyeCamera3D[name] = camPt
            let d = max(-camPt.z, 0.08)
            eyeDepths[name] = d
            if let proj = eyePose.project(worldPt) {
                eyeJoints2D[name] = proj.center
            }
        }

        let thumb = eyeJoints2D[.thumbTip] ?? pinchPoint
        let index = eyeJoints2D[.indexTip] ?? pinchPoint
        let newPinchPoint = CGPoint(x: (thumb.x + index.x) * 0.5, y: (thumb.y + index.y) * 0.5)

        let wrist = eyeJoints2D[.wrist] ?? palmCenter
        let middle = eyeJoints2D[.middleMCP] ?? palmCenter
        let newPalmCenter = CGPoint(x: (wrist.x + middle.x) * 0.5, y: (wrist.y + middle.y) * 0.5)

        let newBones = HandTracker.buildBones3D(joints2D: eyeJoints2D,
                                                jointsCamera3D: eyeCamera3D,
                                                jointDepths: eyeDepths,
                                                fallbackDepth: depthMeters)

        return HandPose(key: key,
                        joints: eyeJoints2D,
                        jointsCamera3D: eyeCamera3D,
                        jointsWorld3D: jointsWorld3D,
                        jointDepths: eyeDepths,
                        bones3D: newBones,
                        depthMeters: depthMeters,
                        hasLiDAR: hasLiDAR,
                        pinchPoint: newPinchPoint,
                        pinchWorld3D: pinchWorld3D,
                        pinch: pinch,
                        openPalm: openPalm,
                        closedFist: closedFist,
                        palmCenter: newPalmCenter,
                        palmNormalCamera3D: palmNormalCamera3D,
                        confidence: confidence)
    }
}

/// Pipeline asíncrono de Hand Tracking:
/// **Apple Vision (`VNDetectHumanHandPoseRequest`, 21 puntos) + Sensor LiDAR + Filtro One-Euro 3D**.
final class HandTracker {

    /// Cadenas cinemáticas de los 5 dedos y el arco metacarpiano.
    static let connections: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
        [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
    ]

    /// Los 19 huesos articulados de la malla low-poly con sus proporciones anatómicas de grosor.
    static let boneDefinitions: [HandBoneDefinition] = [
        // Pulgar (0)
        HandBoneDefinition(parent: .wrist, child: .thumbCMC, fingerIndex: 0, segmentIndex: 0, radiusStartRatio: 0.235, radiusEndRatio: 0.210),
        HandBoneDefinition(parent: .thumbCMC, child: .thumbMP, fingerIndex: 0, segmentIndex: 1, radiusStartRatio: 0.210, radiusEndRatio: 0.176),
        HandBoneDefinition(parent: .thumbMP, child: .thumbIP, fingerIndex: 0, segmentIndex: 2, radiusStartRatio: 0.176, radiusEndRatio: 0.152),
        HandBoneDefinition(parent: .thumbIP, child: .thumbTip, fingerIndex: 0, segmentIndex: 3, radiusStartRatio: 0.152, radiusEndRatio: 0.128),
        // Índice (1)
        HandBoneDefinition(parent: .wrist, child: .indexMCP, fingerIndex: 1, segmentIndex: 0, radiusStartRatio: 0.195, radiusEndRatio: 0.168),
        HandBoneDefinition(parent: .indexMCP, child: .indexPIP, fingerIndex: 1, segmentIndex: 1, radiusStartRatio: 0.168, radiusEndRatio: 0.144),
        HandBoneDefinition(parent: .indexPIP, child: .indexDIP, fingerIndex: 1, segmentIndex: 2, radiusStartRatio: 0.144, radiusEndRatio: 0.124),
        HandBoneDefinition(parent: .indexDIP, child: .indexTip, fingerIndex: 1, segmentIndex: 3, radiusStartRatio: 0.124, radiusEndRatio: 0.108),
        // Medio (2)
        HandBoneDefinition(parent: .wrist, child: .middleMCP, fingerIndex: 2, segmentIndex: 0, radiusStartRatio: 0.200, radiusEndRatio: 0.174),
        HandBoneDefinition(parent: .middleMCP, child: .middlePIP, fingerIndex: 2, segmentIndex: 1, radiusStartRatio: 0.174, radiusEndRatio: 0.150),
        HandBoneDefinition(parent: .middlePIP, child: .middleDIP, fingerIndex: 2, segmentIndex: 2, radiusStartRatio: 0.150, radiusEndRatio: 0.128),
        HandBoneDefinition(parent: .middleDIP, child: .middleTip, fingerIndex: 2, segmentIndex: 3, radiusStartRatio: 0.128, radiusEndRatio: 0.112),
        // Anular (3)
        HandBoneDefinition(parent: .wrist, child: .ringMCP, fingerIndex: 3, segmentIndex: 0, radiusStartRatio: 0.190, radiusEndRatio: 0.162),
        HandBoneDefinition(parent: .ringMCP, child: .ringPIP, fingerIndex: 3, segmentIndex: 1, radiusStartRatio: 0.162, radiusEndRatio: 0.138),
        HandBoneDefinition(parent: .ringPIP, child: .ringDIP, fingerIndex: 3, segmentIndex: 2, radiusStartRatio: 0.138, radiusEndRatio: 0.118),
        HandBoneDefinition(parent: .ringDIP, child: .ringTip, fingerIndex: 3, segmentIndex: 3, radiusStartRatio: 0.118, radiusEndRatio: 0.102),
        // Meñique (4)
        HandBoneDefinition(parent: .wrist, child: .littleMCP, fingerIndex: 4, segmentIndex: 0, radiusStartRatio: 0.175, radiusEndRatio: 0.146),
        HandBoneDefinition(parent: .littleMCP, child: .littlePIP, fingerIndex: 4, segmentIndex: 1, radiusStartRatio: 0.146, radiusEndRatio: 0.122),
        HandBoneDefinition(parent: .littlePIP, child: .littleDIP, fingerIndex: 4, segmentIndex: 2, radiusStartRatio: 0.122, radiusEndRatio: 0.104),
        HandBoneDefinition(parent: .littleDIP, child: .littleTip, fingerIndex: 4, segmentIndex: 3, radiusStartRatio: 0.104, radiusEndRatio: 0.090)
    ]

    private let queue = DispatchQueue(label: "mixr.hand-tracker", qos: .userInteractive)
    private let request = VNDetectHumanHandPoseRequest()
    private let sequence = VNSequenceRequestHandler()

    /// Zona de detección amplia pero descartando el borde inferior extremo (piernas/torso).
    static let detectionBand = CGRect(x: 0.03, y: 0.0, width: 0.94, height: 0.90)

    /// Bancos de filtros One-Euro por mano ("L"/"R") y por articulación (21 puntos).
    private var filters2D: [String: [VNHumanHandPoseObservation.JointName: OneEuroFilter2D]] = [:]
    private var filters3D: [String: [VNHumanHandPoseObservation.JointName: OneEuroFilter3D]] = [:]
    private var depthFilters: [String: OneEuroFilter1D] = [:]

    /// Última pose por mano para puenteo de micro-oclusiones (< 220 ms).
    private var lastPoses: [String: HandPose] = [:]
    private var lastSeen: [String: CFTimeInterval] = [:]
    private var lastProcessedAt: CFTimeInterval = 0
    var interval: TimeInterval = Config.handTrackingInterval
    private var busy = false

    init() {
        request.maximumHandCount = 2
    }

    /// Encola un frame de cámara + mapa de profundidad LiDAR para procesarlo de forma
    /// asíncrona y devolver las poses 3D suavizadas con One-Euro.
    func submit(pixelBuffer: CVPixelBuffer,
                depthMap: CVPixelBuffer? = nil,
                confidenceMap: CVPixelBuffer? = nil,
                pose: CameraPose? = nil,
                viewportSize: CGSize,
                imageAspect: CGFloat,
                orientation: CGImagePropertyOrientation,
                completion: @escaping ([HandPose]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.busy else { return }

            let now = CACurrentMediaTime()
            guard now - self.lastProcessedAt >= self.interval else { return }
            self.lastProcessedAt = now
            self.busy = true

            let poses = self.detect(pixelBuffer: pixelBuffer,
                                    depthMap: depthMap,
                                    confidenceMap: confidenceMap,
                                    pose: pose,
                                    viewportSize: viewportSize,
                                    imageAspect: imageAspect,
                                    orientation: orientation,
                                    timestamp: now)
            self.busy = false
            completion(poses)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.filters2D.removeAll()
            self.filters3D.removeAll()
            self.depthFilters.removeAll()
            self.lastPoses.removeAll()
            self.lastSeen.removeAll()
        }
    }

    // MARK: - Detección Vision + Fusión LiDAR + One-Euro

    private func detect(pixelBuffer: CVPixelBuffer,
                        depthMap: CVPixelBuffer?,
                        confidenceMap: CVPixelBuffer?,
                        pose: CameraPose?,
                        viewportSize: CGSize,
                        imageAspect: CGFloat,
                        orientation: CGImagePropertyOrientation,
                        timestamp: CFTimeInterval) -> [HandPose] {
        do {
            try sequence.perform([request], on: pixelBuffer, orientation: orientation)
        } catch {
            return []
        }

        let observations = request.results ?? []
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

            // 1. Proyección 2D + Suavizado One-Euro 2D por articulación.
            var joints2D: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            for (name, point) in raw where point.confidence > 0.15 {
                let mapped = projector.map(CGPoint(x: CGFloat(point.location.x),
                                                   y: CGFloat(point.location.y)))
                joints2D[name] = filterJoint2D(key: key, name: name, value: mapped, timestamp: timestamp)
            }
            guard joints2D.count >= 5 else { continue }
            guard let thumb = joints2D[.thumbTip], let index = joints2D[.indexTip] else { continue }
            guard let wrist = joints2D[.wrist], let middle = joints2D[.middleMCP] else { continue }

            let handSize = hypot(wrist.x - middle.x, wrist.y - middle.y)
            guard handSize > 1 else { continue }

            let palmCenter = CGPoint(x: (wrist.x + middle.x) * 0.5, y: (wrist.y + middle.y) * 0.5)

            // Filtrado espacial de zona activa.
            guard viewportSize.width > 1, viewportSize.height > 1 else { continue }
            let band = Self.detectionBand
            let allowed = CGRect(x: viewportSize.width * band.minX,
                                 y: viewportSize.height * band.minY,
                                 width: viewportSize.width * band.width,
                                 height: viewportSize.height * band.height)
            guard allowed.contains(palmCenter) else { continue }

            // 2. Reconstrucción 3D enriquecida con LiDAR + Suavizado One-Euro 3D.
            var jointsCamera3D: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
            var jointsWorld3D: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
            var jointDepths: [VNHumanHandPoseObservation.JointName: Float] = [:]
            var smoothedPalmDepth: Float = 0.42
            var hasLiDAR = false

            if let pose {
                let recon = HandDepthSampler.reconstructHand3D(screenJoints: joints2D,
                                                               depthMap: depthMap,
                                                               confidenceMap: confidenceMap,
                                                               pose: pose)
                hasLiDAR = recon.hasLiDAR
                smoothedPalmDepth = filterDepth1D(key: key, value: recon.palmDepthMeters, timestamp: timestamp)

                for (name, rawCam3D) in recon.cameraJoints {
                    let filteredCam3D = filterJoint3D(key: key, name: name, value: rawCam3D, timestamp: timestamp)
                    jointsCamera3D[name] = filteredCam3D
                    jointsWorld3D[name] = pose.cameraToWorld(filteredCam3D)
                    jointDepths[name] = max(-filteredCam3D.z, 0.08)
                }
            } else {
                // Respaldo cuando aún no hay CameraPose en el primer tick.
                let approxDepth = Float(min(max(240.0 * 0.088 / max(handSize, 12.0), 0.16), 1.40))
                smoothedPalmDepth = filterDepth1D(key: key, value: approxDepth, timestamp: timestamp)
                for (name, pt) in joints2D {
                    let cam3D = simd_float3(Float(pt.x - viewportSize.width * 0.5) * 0.0015 * smoothedPalmDepth,
                                            Float(viewportSize.height * 0.5 - pt.y) * 0.0015 * smoothedPalmDepth,
                                            -smoothedPalmDepth)
                    let filteredCam3D = filterJoint3D(key: key, name: name, value: cam3D, timestamp: timestamp)
                    jointsCamera3D[name] = filteredCam3D
                    jointsWorld3D[name] = filteredCam3D
                    jointDepths[name] = smoothedPalmDepth
                }
            }

            // 3. Cálculo de orientaciones 3D de huesos y normal de palma.
            let bones3D = Self.buildBones3D(joints2D: joints2D,
                                            jointsCamera3D: jointsCamera3D,
                                            jointDepths: jointDepths,
                                            fallbackDepth: smoothedPalmDepth)
            let palmNormal = Self.computePalmNormal(jointsCamera3D: jointsCamera3D)

            // 4. Pinza y gestos (combinando distancia proyectada y distancia 3D real).
            let pinchPoint = CGPoint(x: (thumb.x + index.x) * 0.5, y: (thumb.y + index.y) * 0.5)
            let pinchWorld3D: simd_float3 = {
                if let t3 = jointsWorld3D[.thumbTip], let i3 = jointsWorld3D[.indexTip] {
                    return (t3 + i3) * 0.5
                }
                return .zero
            }()

            let ratio2D = hypot(thumb.x - index.x, thumb.y - index.y) / handSize
            var pinch = min(max(1 - ratio2D / 0.9, 0), 1)

            var keyConfidence: CGFloat = 1
            for name in [VNHumanHandPoseObservation.JointName.thumbTip, .indexTip, .middleMCP, .wrist] {
                if let point = raw[name] { keyConfidence = min(keyConfidence, CGFloat(point.confidence)) }
            }

            let millimeters = ratio2D * 90
            if !otherFingersRelaxed(joints2D) || millimeters > 22 {
                pinch = min(pinch, 0.25)
            }

            let openPalm = Self.allFingersExtended(joints2D)
            let closedFist = Self.isClosedFist(joints2D)

            poses.append(HandPose(key: key,
                                  joints: joints2D,
                                  jointsCamera3D: jointsCamera3D,
                                  jointsWorld3D: jointsWorld3D,
                                  jointDepths: jointDepths,
                                  bones3D: bones3D,
                                  depthMeters: smoothedPalmDepth,
                                  hasLiDAR: hasLiDAR,
                                  pinchPoint: pinchPoint,
                                  pinchWorld3D: pinchWorld3D,
                                  pinch: pinch,
                                  openPalm: openPalm,
                                  closedFist: closedFist,
                                  palmCenter: palmCenter,
                                  palmNormalCamera3D: palmNormal,
                                  confidence: keyConfidence))
        }

        // Persistencia corta (~220 ms) ante pérdida momentánea de un frame de Vision.
        for (key, stored) in lastPoses where !seen.contains(key) {
            if timestamp - (lastSeen[key] ?? 0) < 0.22 {
                poses.append(stored)
            }
        }
        for pose in poses where seen.contains(pose.key) {
            lastPoses[pose.key] = pose
            lastSeen[pose.key] = timestamp
        }
        for key in lastPoses.keys where timestamp - (lastSeen[key] ?? 0) > 0.45 {
            lastPoses[key] = nil
            lastSeen[key] = nil
            filters2D[key] = nil
            filters3D[key] = nil
            depthFilters[key] = nil
        }

        return poses
    }

    // MARK: - Construcción de huesos 3D para la malla low-poly

    static func buildBones3D(joints2D: [VNHumanHandPoseObservation.JointName: CGPoint],
                             jointsCamera3D: [VNHumanHandPoseObservation.JointName: simd_float3],
                             jointDepths: [VNHumanHandPoseObservation.JointName: Float],
                             fallbackDepth: Float) -> [HandBonePose3D] {
        var result: [HandBonePose3D] = []
        result.reserveCapacity(boneDefinitions.count)

        let upRef = simd_float3(0, 1, 0)
        for def in boneDefinitions {
            guard let p0 = joints2D[def.parent], let p1 = joints2D[def.child] else { continue }
            let c0 = jointsCamera3D[def.parent] ?? simd_float3(0, 0, -fallbackDepth)
            let c1 = jointsCamera3D[def.child] ?? simd_float3(0, 0, -fallbackDepth)

            let diff = c1 - c0
            let len = simd_length(diff)
            let dir = len > 0.0001 ? (diff / len) : upRef
            let rot = simd_quatf(from: upRef, to: dir)

            let d0 = jointDepths[def.parent] ?? fallbackDepth
            let d1 = jointDepths[def.child] ?? fallbackDepth
            let avgDepth = (d0 + d1) * 0.5

            result.append(HandBonePose3D(definition: def,
                                         start2D: p0,
                                         end2D: p1,
                                         startCamera3D: c0,
                                         endCamera3D: c1,
                                         rotation3D: rot,
                                         depthMeters: avgDepth))
        }
        return result
    }

    private static func computePalmNormal(jointsCamera3D: [VNHumanHandPoseObservation.JointName: simd_float3]) -> simd_float3 {
        guard let wrist = jointsCamera3D[.wrist],
              let index = jointsCamera3D[.indexMCP],
              let little = jointsCamera3D[.littleMCP] else {
            return simd_float3(0, 0, 1)
        }
        let v1 = index - wrist
        let v2 = little - wrist
        let cross = simd_cross(v1, v2)
        let len = simd_length(cross)
        return len > 0.0001 ? (cross / len) : simd_float3(0, 0, 1)
    }

    // MARK: - Bancos de Filtros One-Euro (2D, 3D y Profundidad)

    private func filterJoint2D(key: String,
                               name: VNHumanHandPoseObservation.JointName,
                               value: CGPoint,
                               timestamp: CFTimeInterval) -> CGPoint {
        var bank = filters2D[key] ?? [:]
        var filter = bank[name] ?? OneEuroFilter2D(minCutoff: 1.45, beta: 0.022, dCutoff: 1.0)
        let result = filter.filter(value, timestamp: timestamp)
        bank[name] = filter
        filters2D[key] = bank
        return result
    }

    private func filterJoint3D(key: String,
                               name: VNHumanHandPoseObservation.JointName,
                               value: simd_float3,
                               timestamp: CFTimeInterval) -> simd_float3 {
        var bank = filters3D[key] ?? [:]
        var filter = bank[name] ?? OneEuroFilter3D(minCutoffXY: 1.50,
                                                   betaXY: 1.90,
                                                   minCutoffZ: 1.15,
                                                   betaZ: 1.40,
                                                   dCutoff: 1.0)
        let result = filter.filter(value, timestamp: timestamp)
        bank[name] = filter
        filters3D[key] = bank
        return result
    }

    private func filterDepth1D(key: String,
                               value: Float,
                               timestamp: CFTimeInterval) -> Float {
        var filter = depthFilters[key] ?? OneEuroFilter1D(minCutoff: 1.15, beta: 1.30, dCutoff: 1.0)
        let result = filter.filter(value, timestamp: timestamp)
        depthFilters[key] = filter
        return result
    }

    // MARK: - Clasificadores geométricos de gestos

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
}

/// Pasa puntos normalizados de Vision (imagen ya parada, origen abajo-izquierda)
/// a coordenadas de pantalla con recorte "aspect fill", igual que la cámara.
struct ImageProjector {
    let viewportSize: CGSize
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
