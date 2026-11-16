import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import UIKit
import Vision
import simd

/// Definición de un hueso anatómico para la malla 3D low-poly de la mano.
struct HandBoneDefinition {
    let parent: VNHumanHandPoseObservation.JointName
    let child: VNHumanHandPoseObservation.JointName
    /// 0 = pulgar, 1 = índice, 2 = medio, 3 = anular, 4 = meñique.
    let fingerIndex: Int
    /// 0 = metacarpiano/proximal, 1 = intermedio, 2 = distal, 3 = punta.
    let segmentIndex: Int
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
    let depthMeters: Float
}

/// Eje 3D del antebrazo (Arm Tracking): permite seguir el brazo aunque el codo
/// quede fuera de cuadro o el dedo se salga del frame.
struct HandForearmPose {
    let wrist2D: CGPoint
    let midForearm2D: CGPoint
    let elbow2D: CGPoint
    let wristCamera3D: simd_float3
    let elbowCamera3D: simd_float3
    let wristWorld3D: simd_float3
    let elbowWorld3D: simd_float3
    let wristDepthMeters: Float
    let elbowDepthMeters: Float
    /// Ancho del antebrazo estimado en puntos de pantalla.
    let widthPoints: CGFloat
    /// Dirección unitaria (2D, pantalla) muñeca → codo.
    let direction2D: CGPoint
}

/// Una mano detectada por Vision + LiDAR, suavizada con One-Euro en 2D y 3D.
struct HandPose {
    let key: String
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    let jointsCamera3D: [VNHumanHandPoseObservation.JointName: simd_float3]
    let jointsWorld3D: [VNHumanHandPoseObservation.JointName: simd_float3]
    let jointDepths: [VNHumanHandPoseObservation.JointName: Float]
    let bones3D: [HandBonePose3D]
    /// Antebrazo/brazo que acompaña a la mano.
    let forearm: HandForearmPose
    let depthMeters: Float
    let hasLiDAR: Bool
    let pinchPoint: CGPoint
    let pinchWorld3D: simd_float3
    let pinch: CGFloat
    let openPalm: Bool
    let closedFist: Bool
    let palmCenter: CGPoint
    let palmNormalCamera3D: simd_float3
    /// Producto escalar entre la normal de la palma y el eje de visión:
    /// > 0 significa que la palma está mirando hacia la cámara del teléfono.
    let palmFacingScore: Float
    let confidence: CGFloat
    /// Escala de la palma en puntos de pantalla (muñeca → nudillo medio).
    let palmScale: CGFloat

    var isPalmFacingCamera: Bool { palmFacingScore > 0.15 }

    /// Desproyecta/reproyecta las 21 articulaciones y el antebrazo a la cámara de un
    /// ojo concreto para conseguir disparidad estereoscópica real en la caja VR.
    func projected(for eyePose: CameraPose) -> HandPose {
        guard !jointsWorld3D.isEmpty else { return self }

        var eye2D: [VNHumanHandPoseObservation.JointName: CGPoint] = joints
        var eyeCam: [VNHumanHandPoseObservation.JointName: simd_float3] = jointsCamera3D
        var eyeDepths: [VNHumanHandPoseObservation.JointName: Float] = jointDepths

        for (name, worldPt) in jointsWorld3D {
            let camPt = eyePose.worldToCamera(worldPt)
            eyeCam[name] = camPt
            eyeDepths[name] = max(-camPt.z, 0.08)
            if let proj = eyePose.project(worldPt) {
                eye2D[name] = proj.center
            }
        }

        let thumb = eye2D[.thumbTip] ?? pinchPoint
        let index = eye2D[.indexTip] ?? pinchPoint
        let newPinch = CGPoint(x: (thumb.x + index.x) * 0.5, y: (thumb.y + index.y) * 0.5)
        let wrist = eye2D[.wrist] ?? palmCenter
        let middle = eye2D[.middleMCP] ?? palmCenter
        let newPalm = CGPoint(x: (wrist.x + middle.x) * 0.5, y: (wrist.y + middle.y) * 0.5)

        let newBones = HandTracker.buildBones3D(joints2D: eye2D,
                                                jointsCamera3D: eyeCam,
                                                jointDepths: eyeDepths,
                                                fallbackDepth: depthMeters)

        var newForearm = forearm
        if let projElbow = eyePose.project(forearm.elbowWorld3D),
           let projWrist = eyePose.project(forearm.wristWorld3D) {
            let mid = CGPoint(x: (projElbow.center.x + projWrist.center.x) * 0.5,
                              y: (projElbow.center.y + projWrist.center.y) * 0.5)
            let dx = projElbow.center.x - projWrist.center.x
            let dy = projElbow.center.y - projWrist.center.y
            let len = max(hypot(dx, dy), 0.001)
            newForearm = HandForearmPose(wrist2D: projWrist.center,
                                         midForearm2D: mid,
                                         elbow2D: projElbow.center,
                                         wristCamera3D: eyePose.worldToCamera(forearm.wristWorld3D),
                                         elbowCamera3D: eyePose.worldToCamera(forearm.elbowWorld3D),
                                         wristWorld3D: forearm.wristWorld3D,
                                         elbowWorld3D: forearm.elbowWorld3D,
                                         wristDepthMeters: projWrist.depth,
                                         elbowDepthMeters: projElbow.depth,
                                         widthPoints: forearm.widthPoints,
                                         direction2D: CGPoint(x: dx / len, y: dy / len))
        }

        return HandPose(key: key,
                        joints: eye2D,
                        jointsCamera3D: eyeCam,
                        jointsWorld3D: jointsWorld3D,
                        jointDepths: eyeDepths,
                        bones3D: newBones,
                        forearm: newForearm,
                        depthMeters: depthMeters,
                        hasLiDAR: hasLiDAR,
                        pinchPoint: newPinch,
                        pinchWorld3D: pinchWorld3D,
                        pinch: pinch,
                        openPalm: openPalm,
                        closedFist: closedFist,
                        palmCenter: newPalm,
                        palmNormalCamera3D: palmNormalCamera3D,
                        palmFacingScore: palmFacingScore,
                        confidence: confidence,
                        palmScale: palmScale)
    }
}

/// Pipeline asíncrono de seguimiento:
/// **Apple Vision (Mano 21 pts + Cuerpo/Brazo) + Sensor LiDAR + Filtro One-Euro 3D**.
final class HandTracker {

    static let connections: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
        [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
    ]

    static let boneDefinitions: [HandBoneDefinition] = [
        HandBoneDefinition(parent: .wrist, child: .thumbCMC, fingerIndex: 0, segmentIndex: 0, radiusStartRatio: 0.235, radiusEndRatio: 0.210),
        HandBoneDefinition(parent: .thumbCMC, child: .thumbMP, fingerIndex: 0, segmentIndex: 1, radiusStartRatio: 0.210, radiusEndRatio: 0.176),
        HandBoneDefinition(parent: .thumbMP, child: .thumbIP, fingerIndex: 0, segmentIndex: 2, radiusStartRatio: 0.176, radiusEndRatio: 0.152),
        HandBoneDefinition(parent: .thumbIP, child: .thumbTip, fingerIndex: 0, segmentIndex: 3, radiusStartRatio: 0.152, radiusEndRatio: 0.128),

        HandBoneDefinition(parent: .wrist, child: .indexMCP, fingerIndex: 1, segmentIndex: 0, radiusStartRatio: 0.195, radiusEndRatio: 0.168),
        HandBoneDefinition(parent: .indexMCP, child: .indexPIP, fingerIndex: 1, segmentIndex: 1, radiusStartRatio: 0.168, radiusEndRatio: 0.144),
        HandBoneDefinition(parent: .indexPIP, child: .indexDIP, fingerIndex: 1, segmentIndex: 2, radiusStartRatio: 0.144, radiusEndRatio: 0.124),
        HandBoneDefinition(parent: .indexDIP, child: .indexTip, fingerIndex: 1, segmentIndex: 3, radiusStartRatio: 0.124, radiusEndRatio: 0.108),

        HandBoneDefinition(parent: .wrist, child: .middleMCP, fingerIndex: 2, segmentIndex: 0, radiusStartRatio: 0.200, radiusEndRatio: 0.174),
        HandBoneDefinition(parent: .middleMCP, child: .middlePIP, fingerIndex: 2, segmentIndex: 1, radiusStartRatio: 0.174, radiusEndRatio: 0.150),
        HandBoneDefinition(parent: .middlePIP, child: .middleDIP, fingerIndex: 2, segmentIndex: 2, radiusStartRatio: 0.150, radiusEndRatio: 0.128),
        HandBoneDefinition(parent: .middleDIP, child: .middleTip, fingerIndex: 2, segmentIndex: 3, radiusStartRatio: 0.128, radiusEndRatio: 0.112),

        HandBoneDefinition(parent: .wrist, child: .ringMCP, fingerIndex: 3, segmentIndex: 0, radiusStartRatio: 0.190, radiusEndRatio: 0.162),
        HandBoneDefinition(parent: .ringMCP, child: .ringPIP, fingerIndex: 3, segmentIndex: 1, radiusStartRatio: 0.162, radiusEndRatio: 0.138),
        HandBoneDefinition(parent: .ringPIP, child: .ringDIP, fingerIndex: 3, segmentIndex: 2, radiusStartRatio: 0.138, radiusEndRatio: 0.118),
        HandBoneDefinition(parent: .ringDIP, child: .ringTip, fingerIndex: 3, segmentIndex: 3, radiusStartRatio: 0.118, radiusEndRatio: 0.102),

        HandBoneDefinition(parent: .wrist, child: .littleMCP, fingerIndex: 4, segmentIndex: 0, radiusStartRatio: 0.175, radiusEndRatio: 0.146),
        HandBoneDefinition(parent: .littleMCP, child: .littlePIP, fingerIndex: 4, segmentIndex: 1, radiusStartRatio: 0.146, radiusEndRatio: 0.122),
        HandBoneDefinition(parent: .littlePIP, child: .littleDIP, fingerIndex: 4, segmentIndex: 2, radiusStartRatio: 0.122, radiusEndRatio: 0.104),
        HandBoneDefinition(parent: .littleDIP, child: .littleTip, fingerIndex: 4, segmentIndex: 3, radiusStartRatio: 0.104, radiusEndRatio: 0.090)
    ]

    private let queue = DispatchQueue(label: "mixr.hand-tracker", qos: .userInteractive)
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let sequence = VNSequenceRequestHandler()

    private var filters2D: [String: [VNHumanHandPoseObservation.JointName: OneEuroFilter2D]] = [:]
    private var filters3D: [String: [VNHumanHandPoseObservation.JointName: OneEuroFilter3D]] = [:]
    private var depthFilters: [String: OneEuroFilter1D] = [:]
    private var armFilters: [String: OneEuroFilter2D] = [:]

    private var lastPoses: [String: HandPose] = [:]
    private var lastSeen: [String: CFTimeInterval] = [:]
    private var lastProcessedAt: CFTimeInterval = 0
    private var lastBodyAt: CFTimeInterval = 0
    private var cachedElbows: [CGPoint] = []
    private var cachedWrists: [CGPoint] = []

    /// Cadencia de Vision (~30 Hz) y del cuerpo (~9 Hz, es lo más caro).
    var interval: TimeInterval = Config.handTrackingInterval
    private var busy = false

    init() {
        handRequest.maximumHandCount = 2
    }

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
            self.armFilters.removeAll()
            self.lastPoses.removeAll()
            self.lastSeen.removeAll()
            self.cachedElbows.removeAll()
            self.cachedWrists.removeAll()
        }
    }

    // MARK: - Detección

    private func detect(pixelBuffer: CVPixelBuffer,
                        depthMap: CVPixelBuffer?,
                        confidenceMap: CVPixelBuffer?,
                        pose: CameraPose?,
                        viewportSize: CGSize,
                        imageAspect: CGFloat,
                        orientation: CGImagePropertyOrientation,
                        timestamp: CFTimeInterval) -> [HandPose] {
        let projector = ImageProjector(viewportSize: viewportSize, imageAspect: imageAspect)

        // --- Arm Tracking: Vision Body Pose (codos y muñecas) a ~9 Hz ---
        if timestamp - lastBodyAt > 0.11 {
            lastBodyAt = timestamp
            do {
                try sequence.perform([bodyRequest], on: pixelBuffer, orientation: orientation)
                if let body = bodyRequest.results?.first,
                   let pts = try? body.recognizedPoints(.all) {
                    cachedElbows = Self.points(named: [.leftElbow, .rightElbow], in: pts, projector: projector)
                    cachedWrists = Self.points(named: [.leftWrist, .rightWrist], in: pts, projector: projector)
                }
            } catch {
                cachedElbows = []
                cachedWrists = []
            }
        }

        do {
            try sequence.perform([handRequest], on: pixelBuffer, orientation: orientation)
        } catch {
            return []
        }

        let observations = handRequest.results ?? []
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

            // 1. Proyección 2D + One-Euro 2D por articulación.
            var joints2D: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            for (name, point) in raw where point.confidence > 0.10 {
                let mapped = projector.map(CGPoint(x: CGFloat(point.location.x),
                                                   y: CGFloat(point.location.y)))
                joints2D[name] = filterJoint2D(key: key, name: name, value: mapped, timestamp: timestamp)
            }
            guard joints2D.count >= 4 else { continue }

            // 2. Completar articulaciones faltantes por cinemática (nunca una mano a medias).
            Self.completeMissingJoints(&joints2D, chiralityKey: key, fallbackCenter: projector.map(.init(x: 0.5, y: 0.4)))

            guard let thumb = joints2D[.thumbTip], let index = joints2D[.indexTip],
                  let wrist = joints2D[.wrist], let middle = joints2D[.middleMCP] else { continue }

            var palmScale = hypot(wrist.x - middle.x, wrist.y - middle.y)
            if palmScale < 6 { palmScale = 34 }
            let palmCenter = CGPoint(x: (wrist.x + middle.x) * 0.5, y: (wrist.y + middle.y) * 0.5)

            // 3. Arm Tracking: codo más cercano a esta muñeca.
            let bestElbow = Self.closestPoint(to: wrist, in: cachedElbows, maxDistance: palmScale * 6.0)

            // 4. Reconstrucción 3D con LiDAR + antebrazo.
            var cameraJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
            var worldJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
            var jointDepths: [VNHumanHandPoseObservation.JointName: Float] = [:]
            var palmDepth: Float = 0.42
            var hasLiDAR = false
            var forearm = HandForearmPose(wrist2D: wrist, midForearm2D: wrist, elbow2D: wrist,
                                          wristCamera3D: .zero, elbowCamera3D: .zero,
                                          wristWorld3D: .zero, elbowWorld3D: .zero,
                                          wristDepthMeters: 0.42, elbowDepthMeters: 0.42,
                                          widthPoints: palmScale * 0.62,
                                          direction2D: CGPoint(x: 0, y: 1))

            if let pose {
                let recon = HandDepthSampler.reconstructHandAndArm3D(screenJoints: joints2D,
                                                                     visionElbow2D: bestElbow,
                                                                     depthMap: depthMap,
                                                                     confidenceMap: confidenceMap,
                                                                     pose: pose)
                hasLiDAR = recon.hasLiDAR
                palmDepth = filterDepth1D(key: key, value: recon.palmDepthMeters, timestamp: timestamp)

                for (name, rawCam3D) in recon.cameraJoints {
                    let filtered = filterJoint3D(key: key, name: name, value: rawCam3D, timestamp: timestamp)
                    cameraJoints[name] = filtered
                    worldJoints[name] = pose.cameraToWorld(filtered)
                    jointDepths[name] = max(-filtered.z, 0.08)
                }

                // Antebrazo: suavizado One-Euro 2D del codo para que no vibre.
                let smoothedElbow = filterArmPoint(key: key, value: recon.forearm.elbow2D, timestamp: timestamp)
                let wDepth = jointDepths[.wrist] ?? palmDepth
                let eDepth = recon.forearm.elbowDepthMeters
                let elbowCam = pose.unprojectToCamera(screenPoint: smoothedElbow, depth: eDepth)
                let wristCam = cameraJoints[.wrist] ?? pose.unprojectToCamera(screenPoint: wrist, depth: wDepth)
                let dir = CGPoint(x: smoothedElbow.x - wrist.x, y: smoothedElbow.y - wrist.y)
                let dirLen = max(hypot(dir.x, dir.y), 0.001)

                forearm = HandForearmPose(wrist2D: wrist,
                                          midForearm2D: CGPoint(x: (wrist.x + smoothedElbow.x) * 0.5,
                                                                y: (wrist.y + smoothedElbow.y) * 0.5),
                                          elbow2D: smoothedElbow,
                                          wristCamera3D: wristCam,
                                          elbowCamera3D: elbowCam,
                                          wristWorld3D: pose.cameraToWorld(wristCam),
                                          elbowWorld3D: pose.cameraToWorld(elbowCam),
                                          wristDepthMeters: wDepth,
                                          elbowDepthMeters: eDepth,
                                          widthPoints: palmScale * 0.60,
                                          direction2D: CGPoint(x: dir.x / dirLen, y: dir.y / dirLen))
            } else {
                palmDepth = filterDepth1D(key: key, value: Float(min(max(240.0 * 0.088 / Double(max(palmScale, 12)), 0.16), 1.40)), timestamp: timestamp)
                let focal = 240.0
                for (name, pt) in joints2D {
                    let cam3D = simd_float3(Float(pt.x - viewportSize.width * 0.5) / Float(focal) * palmDepth,
                                            Float(viewportSize.height * 0.5 - pt.y) / Float(focal) * palmDepth,
                                            -palmDepth)
                    let filtered = filterJoint3D(key: key, name: name, value: cam3D, timestamp: timestamp)
                    cameraJoints[name] = filtered
                    worldJoints[name] = filtered
                    jointDepths[name] = palmDepth
                }
            }

            let bones3D = Self.buildBones3D(joints2D: joints2D,
                                            jointsCamera3D: cameraJoints,
                                            jointDepths: jointDepths,
                                            fallbackDepth: palmDepth)
            let palmNormal = Self.computePalmNormal(jointsCamera3D: cameraJoints)
            let facing: Float = {
                // La cámara mira hacia -Z: si la normal apunta a +Z, la palma encara al teléfono.
                let viewAxis = simd_float3(0, 0, 1)
                return simd_dot(palmNormal, viewAxis)
            }()

            // 5. Gestos geométricos.
            let pinchPoint = CGPoint(x: (thumb.x + index.x) * 0.5, y: (thumb.y + index.y) * 0.5)
            let pinchWorld3D: simd_float3 = {
                if let t3 = worldJoints[.thumbTip], let i3 = worldJoints[.indexTip] {
                    return (t3 + i3) * 0.5
                }
                return .zero
            }()

            // Distancia 3D real (metros) si el LiDAR la conoce; si no, la normalizada.
            let ratio2D = hypot(thumb.x - index.x, thumb.y - index.y) / palmScale
            var pinch = min(max(1 - ratio2D / 0.9, 0), 1)

            if let t3 = cameraJoints[.thumbTip], let i3 = cameraJoints[.indexTip] {
                let metric = simd_distance(t3, i3)
                // Palma adulta ≈ 8.8 cm -> un roce útil está por debajo de 2.6 cm.
                let metricPinch = Float(min(max(1.0 - (metric - 0.008) / 0.030, 0.0), 1.0))
                pinch = CGFloat(max(pinch, metricPinch))
            }

            var keyConfidence: CGFloat = 1
            for name in [VNHumanHandPoseObservation.JointName.thumbTip, .indexTip, .middleMCP, .wrist] {
                if let point = raw[name] { keyConfidence = min(keyConfidence, CGFloat(point.confidence)) }
            }

            // Anti clics fantasma: la pinza sólo cuenta con los otros dedos recogidos o
            // si la distancia métrica 3D es realmente corta.
            if !otherFingersRelaxed(joints2D) && keyConfidence < 0.85 && pinch < 0.8 {
                pinch = min(pinch, 0.25)
            }

            poses.append(HandPose(key: key,
                                  joints: joints2D,
                                  jointsCamera3D: cameraJoints,
                                  jointsWorld3D: worldJoints,
                                  jointDepths: jointDepths,
                                  bones3D: bones3D,
                                  forearm: forearm,
                                  depthMeters: palmDepth,
                                  hasLiDAR: hasLiDAR,
                                  pinchPoint: pinchPoint,
                                  pinchWorld3D: pinchWorld3D,
                                  pinch: pinch,
                                  openPalm: Self.allFingersExtended(joints2D),
                                  closedFist: Self.isClosedFist(joints2D),
                                  palmCenter: palmCenter,
                                  palmNormalCamera3D: palmNormal,
                                  palmFacingScore: facing,
                                  confidence: keyConfidence,
                                  palmScale: palmScale))
        }

        // Persistencia corta ante micro-pérdidas (sin parpadeo de la malla).
        for (key, stored) in lastPoses where !seen.contains(key) {
            if timestamp - (lastSeen[key] ?? 0) < 0.24 {
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
            armFilters[key] = nil
        }

        return poses
    }

    // MARK: - Completado cinemático de articulaciones

    /// Si Vision no devuelve una articulación (dedo fuera del frame, oclusión parcial),
    /// se estima con la cadena anatómica para que la malla nunca quede mutilada.
    private static func completeMissingJoints(_ joints: inout [VNHumanHandPoseObservation.JointName: CGPoint],
                                              chiralityKey: String,
                                              fallbackCenter: CGPoint) {
        guard let wrist = joints[.wrist] else { return }
        let palmDir: CGPoint = {
            if let middle = joints[.middleMCP] {
                let dx = middle.x - wrist.x
                let dy = middle.y - wrist.y
                let len = max(hypot(dx, dy), 0.001)
                return CGPoint(x: dx / len, y: dy / len)
            }
            return CGPoint(x: 0, y: -1)
        }()
        let scale: CGFloat = {
            if let middle = joints[.middleMCP] { return max(hypot(middle.x - wrist.x, middle.y - wrist.y), 12) }
            return 34
        }()

        // Nudillos faltantes: repartidos lateralmente desde el nudillo medio.
        let lateral = CGPoint(x: -palmDir.y, y: palmDir.x)
        let mcpLayout: [(VNHumanHandPoseObservation.JointName, CGFloat)] = [
            (.indexMCP, -0.52), (.middleMCP, 0.0), (.ringMCP, 0.48), (.littleMCP, 0.92)
        ]
        for (name, offset) in mcpLayout where joints[name] == nil {
            joints[name] = CGPoint(x: wrist.x + palmDir.x * scale + lateral.x * scale * offset,
                                   y: wrist.y + palmDir.y * scale + lateral.y * scale * offset)
        }

        // Falanges faltantes: continuación del hueso anterior.
        let chains: [[(VNHumanHandPoseObservation.JointName, CGFloat)]] = [
            [(.thumbCMC, 0.40), (.thumbMP, 0.42), (.thumbIP, 0.34), (.thumbTip, 0.30)],
            [(.indexMCP, 1.00), (.indexPIP, 0.52), (.indexDIP, 0.30), (.indexTip, 0.24)],
            [(.middleMCP, 1.00), (.middlePIP, 0.56), (.middleDIP, 0.32), (.middleTip, 0.26)],
            [(.ringMCP, 1.00), (.ringPIP, 0.52), (.ringDIP, 0.30), (.ringTip, 0.24)],
            [(.littleMCP, 1.00), (.littlePIP, 0.42), (.littleDIP, 0.26), (.littleTip, 0.22)]
        ]

        for chain in chains {
            var previousPoint = wrist
            for (name, ratio) in chain {
                if let existing = joints[name] {
                    previousPoint = existing
                    continue
                }
                let step = max(scale * ratio, 6)
                joints[name] = CGPoint(x: previousPoint.x + palmDir.x * step,
                                       y: previousPoint.y + palmDir.y * step)
                previousPoint = joints[name]!
            }
        }

        // Si tras completar sigue sin haber muñeca utilizable, usar el centro de respaldo.
        if joints.isEmpty {
            joints[.wrist] = fallbackCenter
        }
    }

    private static func points(named names: [VNHumanBodyPoseObservation.JointName],
                               in pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                               projector: ImageProjector) -> [CGPoint] {
        var out: [CGPoint] = []
        for name in names {
            guard let p = pts[name], p.confidence > 0.25 else { continue }
            out.append(projector.map(CGPoint(x: CGFloat(p.location.x), y: CGFloat(p.location.y))))
        }
        return out
    }

    private static func closestPoint(to target: CGPoint, in candidates: [CGPoint], maxDistance: CGFloat) -> CGPoint? {
        var best: CGPoint?
        var bestDist = maxDistance
        for c in candidates {
            let d = hypot(c.x - target.x, c.y - target.y)
            if d < bestDist {
                bestDist = d
                best = c
            }
        }
        return best
    }

    // MARK: - Huesos 3D

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
            let avgDepth = ((jointDepths[def.parent] ?? fallbackDepth) + (jointDepths[def.child] ?? fallbackDepth)) * 0.5
            result.append(HandBonePose3D(definition: def, start2D: p0, end2D: p1,
                                         startCamera3D: c0, endCamera3D: c1,
                                         rotation3D: rot, depthMeters: avgDepth))
        }
        return result
    }

    private static func computePalmNormal(jointsCamera3D: [VNHumanHandPoseObservation.JointName: simd_float3]) -> simd_float3 {
        guard let wrist = jointsCamera3D[.wrist],
              let index = jointsCamera3D[.indexMCP],
              let little = jointsCamera3D[.littleMCP] else {
            return simd_float3(0, 0, 1)
        }
        let cross = simd_cross(index - wrist, little - wrist)
        let len = simd_length(cross)
        return len > 0.0001 ? (cross / len) : simd_float3(0, 0, 1)
    }

    // MARK: - Filtros One-Euro

    private func filterJoint2D(key: String,
                               name: VNHumanHandPoseObservation.JointName,
                               value: CGPoint,
                               timestamp: CFTimeInterval) -> CGPoint {
        var bank = filters2D[key] ?? [:]
        var filter = bank[name] ?? OneEuroFilter2D(minCutoff: 1.60, beta: 0.024, dCutoff: 1.0)
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
        var filter = bank[name] ?? OneEuroFilter3D(minCutoffXY: 1.65, betaXY: 2.10,
                                                   minCutoffZ: 1.20, betaZ: 1.50,
                                                   dCutoff: 1.0)
        let result = filter.filter(value, timestamp: timestamp)
        bank[name] = filter
        filters3D[key] = bank
        return result
    }

    private func filterDepth1D(key: String, value: Float, timestamp: CFTimeInterval) -> Float {
        var filter = depthFilters[key] ?? OneEuroFilter1D(minCutoff: 1.20, beta: 1.40, dCutoff: 1.0)
        let result = filter.filter(value, timestamp: timestamp)
        depthFilters[key] = filter
        return result
    }

    private func filterArmPoint(key: String, value: CGPoint, timestamp: CFTimeInterval) -> CGPoint {
        var filter = armFilters[key] ?? OneEuroFilter2D(minCutoff: 1.05, beta: 0.012, dCutoff: 1.0)
        let result = filter.filter(value, timestamp: timestamp)
        armFilters[key] = filter
        return result
    }

    // MARK: - Clasificadores

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
        guard let wrist = joints[.wrist] else { return false }
        let pairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.middleTip, .middleMCP), (.ringTip, .ringMCP), (.littleTip, .littleMCP)
        ]
        var curled = 0
        for (tipName, mcpName) in pairs {
            guard let tip = joints[tipName], let mcp = joints[mcpName] else { continue }
            let tipDistance = hypot(tip.x - wrist.x, tip.y - wrist.y)
            let mcpDistance = max(hypot(mcp.x - wrist.x, mcp.y - wrist.y), 1)
            if tipDistance / mcpDistance < 1.22 { curled += 1 }
        }
        return curled == 3
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
