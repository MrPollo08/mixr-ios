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
    /// 0 = proximal, 1 = intermedio, 2 = distal, 3 = punta.
    let segmentIndex: Int
    let radiusStartRatio: CGFloat
    let radiusEndRatio: CGFloat
}

/// Un hueso 3D ya calculado y suavizado con One-Euro.
struct HandBonePose3D {
    let definition: HandBoneDefinition
    let start2D: CGPoint
    let end2D: CGPoint
    let startCamera3D: simd_float3
    let endCamera3D: simd_float3
    let rotation3D: simd_quatf
    let depthMeters: Float
}

/// Eje 3D del antebrazo (Arm Tracking).
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
    let widthPoints: CGFloat
    /// Dirección unitaria (pantalla) muñeca → codo.
    let direction2D: CGPoint
}

/// Una mano detectada: 21 articulaciones 2D y 3D, huesos y antebrazo.
struct HandPose {
    let key: String
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    let jointsCamera3D: [VNHumanHandPoseObservation.JointName: simd_float3]
    let jointsWorld3D: [VNHumanHandPoseObservation.JointName: simd_float3]
    let jointDepths: [VNHumanHandPoseObservation.JointName: Float]
    let bones3D: [HandBonePose3D]
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
    /// > 0 significa palma mirando al teléfono (corregido por lateralidad).
    let palmFacingScore: Float
    let confidence: CGFloat
    let palmScale: CGFloat

    var isPalmFacingCamera: Bool { palmFacingScore > 0.35 }

    /// Tres dedos extendidos: distingue mano abierta de pinza o de señalar.
    var isOpenHand: Bool {
        guard let wrist = joints[.wrist] else { return false }
        let pairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.middleTip, .middleMCP), (.ringTip, .ringMCP), (.littleTip, .littleMCP)
        ]
        var extended = 0
        for (tipName, mcpName) in pairs {
            guard let tip = joints[tipName], let mcp = joints[mcpName] else { continue }
            let tipDistance = hypot(tip.x - wrist.x, tip.y - wrist.y)
            let mcpDistance = max(hypot(mcp.x - wrist.x, mcp.y - wrist.y), 1)
            if tipDistance / mcpDistance > 1.25 { extended += 1 }
        }
        return extended == 3
    }

    /// Copia con articulaciones 2D nuevas (predicción de movimiento).
    func replacingJoints(_ newJoints: [VNHumanHandPoseObservation.JointName: CGPoint]) -> HandPose {
        let thumb = newJoints[.thumbTip] ?? pinchPoint
        let index = newJoints[.indexTip] ?? pinchPoint
        let wrist = newJoints[.wrist] ?? palmCenter
        let middle = newJoints[.middleMCP] ?? palmCenter

        return HandPose(key: key,
                        joints: newJoints,
                        jointsCamera3D: jointsCamera3D,
                        jointsWorld3D: jointsWorld3D,
                        jointDepths: jointDepths,
                        bones3D: bones3D,
                        forearm: forearm,
                        depthMeters: depthMeters,
                        hasLiDAR: hasLiDAR,
                        pinchPoint: CGPoint(x: (thumb.x + index.x) * 0.5,
                                            y: (thumb.y + index.y) * 0.5),
                        pinchWorld3D: pinchWorld3D,
                        pinch: pinch,
                        openPalm: openPalm,
                        closedFist: closedFist,
                        palmCenter: CGPoint(x: (wrist.x + middle.x) * 0.5,
                                            y: (wrist.y + middle.y) * 0.5),
                        palmNormalCamera3D: palmNormalCamera3D,
                        palmFacingScore: palmFacingScore,
                        confidence: confidence,
                        palmScale: palmScale)
    }

    /// Reproyecta las 21 articulaciones y el antebrazo al ojo indicado (VR box).
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
        let wrist = eye2D[.wrist] ?? palmCenter
        let middle = eye2D[.middleMCP] ?? palmCenter

        let newBones = HandTracker.buildBones3D(joints2D: eye2D,
                                                jointsCamera3D: eyeCam,
                                                jointDepths: eyeDepths,
                                                fallbackDepth: depthMeters)

        var newForearm = forearm
        if let projElbow = eyePose.project(forearm.elbowWorld3D),
           let projWrist = eyePose.project(forearm.wristWorld3D) {
            let dx = projElbow.center.x - projWrist.center.x
            let dy = projElbow.center.y - projWrist.center.y
            let len = max(hypot(dx, dy), 0.001)
            newForearm = HandForearmPose(wrist2D: projWrist.center,
                                         midForearm2D: CGPoint(x: (projElbow.center.x + projWrist.center.x) * 0.5,
                                                               y: (projElbow.center.y + projWrist.center.y) * 0.5),
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
                        pinchPoint: CGPoint(x: (thumb.x + index.x) * 0.5,
                                            y: (thumb.y + index.y) * 0.5),
                        pinchWorld3D: pinchWorld3D,
                        pinch: pinch,
                        openPalm: openPalm,
                        closedFist: closedFist,
                        palmCenter: CGPoint(x: (wrist.x + middle.x) * 0.5,
                                            y: (wrist.y + middle.y) * 0.5),
                        palmNormalCamera3D: palmNormalCamera3D,
                        palmFacingScore: palmFacingScore,
                        confidence: confidence,
                        palmScale: palmScale)
    }
}

/// Pipeline asíncrono:
/// **Apple Vision (mano 21 pts + cuerpo/brazo) + LiDAR + filtro One-Euro 3D**.
final class HandTracker {

    static let connections: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
        [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
    ]

    /// Radios anatómicos medidos sobre una mano adulta (fracción de la palma).
    static let boneDefinitions: [HandBoneDefinition] = [
        HandBoneDefinition(parent: .wrist, child: .thumbCMC, fingerIndex: 0, segmentIndex: 0, radiusStartRatio: 0.150, radiusEndRatio: 0.138),
        HandBoneDefinition(parent: .thumbCMC, child: .thumbMP, fingerIndex: 0, segmentIndex: 1, radiusStartRatio: 0.138, radiusEndRatio: 0.126),
        HandBoneDefinition(parent: .thumbMP, child: .thumbIP, fingerIndex: 0, segmentIndex: 2, radiusStartRatio: 0.126, radiusEndRatio: 0.114),
        HandBoneDefinition(parent: .thumbIP, child: .thumbTip, fingerIndex: 0, segmentIndex: 3, radiusStartRatio: 0.114, radiusEndRatio: 0.103),

        HandBoneDefinition(parent: .wrist, child: .indexMCP, fingerIndex: 1, segmentIndex: 0, radiusStartRatio: 0.132, radiusEndRatio: 0.124),
        HandBoneDefinition(parent: .indexMCP, child: .indexPIP, fingerIndex: 1, segmentIndex: 1, radiusStartRatio: 0.124, radiusEndRatio: 0.115),
        HandBoneDefinition(parent: .indexPIP, child: .indexDIP, fingerIndex: 1, segmentIndex: 2, radiusStartRatio: 0.115, radiusEndRatio: 0.106),
        HandBoneDefinition(parent: .indexDIP, child: .indexTip, fingerIndex: 1, segmentIndex: 3, radiusStartRatio: 0.106, radiusEndRatio: 0.096),

        HandBoneDefinition(parent: .wrist, child: .middleMCP, fingerIndex: 2, segmentIndex: 0, radiusStartRatio: 0.140, radiusEndRatio: 0.131),
        HandBoneDefinition(parent: .middleMCP, child: .middlePIP, fingerIndex: 2, segmentIndex: 1, radiusStartRatio: 0.131, radiusEndRatio: 0.121),
        HandBoneDefinition(parent: .middlePIP, child: .middleDIP, fingerIndex: 2, segmentIndex: 2, radiusStartRatio: 0.121, radiusEndRatio: 0.112),
        HandBoneDefinition(parent: .middleDIP, child: .middleTip, fingerIndex: 2, segmentIndex: 3, radiusStartRatio: 0.112, radiusEndRatio: 0.102),

        HandBoneDefinition(parent: .wrist, child: .ringMCP, fingerIndex: 3, segmentIndex: 0, radiusStartRatio: 0.128, radiusEndRatio: 0.120),
        HandBoneDefinition(parent: .ringMCP, child: .ringPIP, fingerIndex: 3, segmentIndex: 1, radiusStartRatio: 0.120, radiusEndRatio: 0.112),
        HandBoneDefinition(parent: .ringPIP, child: .ringDIP, fingerIndex: 3, segmentIndex: 2, radiusStartRatio: 0.112, radiusEndRatio: 0.103),
        HandBoneDefinition(parent: .ringDIP, child: .ringTip, fingerIndex: 3, segmentIndex: 3, radiusStartRatio: 0.103, radiusEndRatio: 0.094),

        HandBoneDefinition(parent: .wrist, child: .littleMCP, fingerIndex: 4, segmentIndex: 0, radiusStartRatio: 0.114, radiusEndRatio: 0.106),
        HandBoneDefinition(parent: .littleMCP, child: .littlePIP, fingerIndex: 4, segmentIndex: 1, radiusStartRatio: 0.106, radiusEndRatio: 0.097),
        HandBoneDefinition(parent: .littlePIP, child: .littleDIP, fingerIndex: 4, segmentIndex: 2, radiusStartRatio: 0.097, radiusEndRatio: 0.089),
        HandBoneDefinition(parent: .littleDIP, child: .littleTip, fingerIndex: 4, segmentIndex: 3, radiusStartRatio: 0.089, radiusEndRatio: 0.082)
    ]

    private let queue = DispatchQueue(label: "mixr.hand-tracker", qos: .userInteractive)
    /// Cola aparte para el cuerpo: es lo más caro y **no debe bloquear** la mano.
    private let bodyQueue = DispatchQueue(label: "mixr.body-tracker", qos: .utility)
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let handSequence = VNSequenceRequestHandler()
    private let bodySequence = VNSequenceRequestHandler()
    /// Motor principal de manos (MediaPipe). Si no arranca, se usa Vision.
    private let mediaPipe = MediaPipeHandTracker()

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

    /// Tamaño real de la palma del usuario, calibrado con LiDAR.
    private var palmCalibration: [String: Float] = [:]
    private var palmCalibrationSamples: [String: Int] = [:]

    /// Cadencia de Vision. El cuerpo va en su propia cola y a ~3 Hz.
    var interval: TimeInterval = Config.handTrackingInterval
    private var bodyBusy = false
    private var busy = false

    init() {
        handRequest.maximumHandCount = 2
    }

    // MARK: - API

    func submit(pixelBuffer: CVPixelBuffer,
                depthMap: CVPixelBuffer? = nil,
                confidenceMap: CVPixelBuffer? = nil,
                pose: CameraPose? = nil,
                viewportSize: CGSize,
                imageAspect: CGFloat,
                orientation: CGImagePropertyOrientation,
                completion: @escaping ([HandPose]) -> Void) {
        // Cuerpo (codo/brazo) en su propia cola, a ~3 Hz, sin frenar la mano.
        if !bodyBusy, CACurrentMediaTime() - lastBodyAt > 0.33 {
            bodyBusy = true
            lastBodyAt = CACurrentMediaTime()
            bodyQueue.async { [weak self] in
                guard let self else { return }
                defer { DispatchQueue.main.async { self.bodyBusy = false } }
                let projector = ImageProjector(viewportSize: viewportSize, imageAspect: imageAspect)
                do {
                    try self.bodySequence.perform([self.bodyRequest],
                                                  on: pixelBuffer,
                                                  orientation: orientation)
                    if let body = self.bodyRequest.results?.first,
                       let pts = try? body.recognizedPoints(.all) {
                        let elbows = Self.collect([.leftElbow, .rightElbow], from: pts, projector: projector)
                        let wrists = Self.collect([.leftWrist, .rightWrist], from: pts, projector: projector)
                        DispatchQueue.main.async {
                            self.cachedElbows = elbows
                            self.cachedWrists = wrists
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.cachedElbows = []
                        self.cachedWrists = []
                    }
                }
            }
        }

        queue.async { [weak self] in
            guard let self else { return }
            // Frame dropeado: si el modelo anterior no terminó, se descarta este.
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
            self.palmCalibration.removeAll()
            self.palmCalibrationSamples.removeAll()
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

        // --- Detección: MediaPipe (principal) con Vision como respaldo ---
        // `rawHands` lleva puntos normalizados (0…1, origen abajo-izquierda) para que el
        // resto del pipeline sea idéntico sin importar qué motor detectó.
        var rawHands: [(key: String, points: [VNHumanHandPoseObservation.JointName: CGPoint],
                        chiralitySign: Float)] = []

        if let mediaPipeHands = mediaPipe.detect(pixelBuffer: pixelBuffer,
                                                  timestamp: timestamp,
                                                  orientation: orientation) {
            rawHands = mediaPipeHands.map {
                (key: $0.key, points: $0.points, chiralitySign: $0.chiralitySign)
            }
        } else {
            do {
                try handSequence.perform([handRequest], on: pixelBuffer, orientation: orientation)
            } catch {
                return persistedPoses(seen: [], timestamp: timestamp)
            }

            for (index, observation) in (handRequest.results ?? []).enumerated() {
                guard let raw = try? observation.recognizedPoints(.all) else { continue }
                var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
                for (name, point) in raw where point.confidence > 0.08 {
                    points[name] = CGPoint(x: CGFloat(point.location.x),
                                           y: CGFloat(point.location.y))
                }
                let key: String
                switch observation.chirality {
                case .left: key = "L"
                case .right: key = "R"
                default: key = "U\(index)"
                }
                let sign: Float = (observation.chirality == .left) ? 1 : -1
                rawHands.append((key: key, points: points, chiralitySign: sign))
            }
        }

        var poses: [HandPose] = []
        var seen = Set<String>()

        for hand in rawHands {
            let key = hand.key
            guard !seen.contains(key) else { continue }

            // 1. Articulaciones 2D con One-Euro por punto.
            var joints2D: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            for (name, normalized) in hand.points {
                let mapped = projector.map(normalized)
                joints2D[name] = filterJoint2D(key: key, name: name, value: mapped, timestamp: timestamp)
            }

            // 2. NUNCA se descarta la mano por faltar puntos: se completa el esqueleto.
            guard joints2D.count >= 2 else { continue }
            Self.completeMissingJoints(&joints2D,
                                       chiralityKey: key,
                                       fallbackCenter: CGPoint(x: viewportSize.width * 0.5,
                                                               y: viewportSize.height * 0.75))

            guard let wrist = joints2D[.wrist], let middleMCP = joints2D[.middleMCP] else { continue }

            var palmScale = hypot(wrist.x - middleMCP.x, wrist.y - middleMCP.y)
            if palmScale < 6 { palmScale = 34 }

            // 3. Estabilización esqueletal.
            Self.enforceMaxBoneLengths(&joints2D, palmScale: palmScale)
            Self.rejectOutliers(&joints2D,
                                previous: lastPoses[key],
                                palmCenter: CGPoint(x: (wrist.x + middleMCP.x) * 0.5,
                                                    y: (wrist.y + middleMCP.y) * 0.5),
                                palmScale: palmScale)

            let finalWrist = joints2D[.wrist] ?? wrist
            let finalMiddle = joints2D[.middleMCP] ?? middleMCP
            var palmScaleFinal = hypot(finalWrist.x - finalMiddle.x, finalWrist.y - finalMiddle.y)
            if palmScaleFinal < 6 { palmScaleFinal = 34 }
            let palmCenter = CGPoint(x: (finalWrist.x + finalMiddle.x) * 0.5,
                                     y: (finalWrist.y + finalMiddle.y) * 0.5)

            seen.insert(key)

            // 4. Codo más cercano a esta muñeca.
            let bestElbow = Self.closest(to: finalWrist, in: cachedElbows,
                                         maxDistance: palmScaleFinal * 6.0)

            // 5. Reconstrucción 3D con LiDAR.
            var cameraJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
            var worldJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
            var jointDepths: [VNHumanHandPoseObservation.JointName: Float] = [:]
            var palmDepth: Float = 0.42
            var hasLiDAR = false
            var forearm = HandForearmPose(wrist2D: finalWrist,
                                          midForearm2D: finalWrist,
                                          elbow2D: finalWrist,
                                          wristCamera3D: .zero,
                                          elbowCamera3D: .zero,
                                          wristWorld3D: .zero,
                                          elbowWorld3D: .zero,
                                          wristDepthMeters: 0.42,
                                          elbowDepthMeters: 0.42,
                                          widthPoints: palmScaleFinal * 0.6,
                                          direction2D: CGPoint(x: 0, y: 1))

            if let pose {
                let recon = HandDepthSampler.reconstructHandAndArm3D(
                    screenJoints: joints2D,
                    visionElbow2D: bestElbow,
                    depthMap: depthMap,
                    confidenceMap: confidenceMap,
                    metricPalmMeters: palmCalibration[key] ?? 0.095,
                    pose: pose
                )
                hasLiDAR = recon.hasLiDAR
                palmDepth = filterDepth1D(key: key, value: recon.palmDepthMeters, timestamp: timestamp)

                if recon.hasLiDAR {
                    updatePalmCalibration(key: key, observed: recon.estimatedPalmMeters)
                }

                for (name, rawCam3D) in recon.cameraJoints {
                    let filtered = filterJoint3D(key: key, name: name, value: rawCam3D, timestamp: timestamp)
                    cameraJoints[name] = filtered
                    worldJoints[name] = pose.cameraToWorld(filtered)
                    jointDepths[name] = max(-filtered.z, 0.08)
                }

                let smoothedElbow = filterArmPoint(key: key, value: recon.forearm.elbow2D, timestamp: timestamp)
                let wristDepth = jointDepths[.wrist] ?? palmDepth
                let elbowDepth = recon.forearm.elbowDepthMeters
                let elbowCam = pose.unprojectToCamera(screenPoint: smoothedElbow, depth: elbowDepth)
                let wristCam = cameraJoints[.wrist] ?? pose.unprojectToCamera(screenPoint: finalWrist,
                                                                             depth: wristDepth)
                let dir = CGPoint(x: smoothedElbow.x - finalWrist.x, y: smoothedElbow.y - finalWrist.y)
                let dirLen = max(hypot(dir.x, dir.y), 0.001)

                forearm = HandForearmPose(wrist2D: finalWrist,
                                          midForearm2D: CGPoint(x: (finalWrist.x + smoothedElbow.x) * 0.5,
                                                                y: (finalWrist.y + smoothedElbow.y) * 0.5),
                                          elbow2D: smoothedElbow,
                                          wristCamera3D: wristCam,
                                          elbowCamera3D: elbowCam,
                                          wristWorld3D: pose.cameraToWorld(wristCam),
                                          elbowWorld3D: pose.cameraToWorld(elbowCam),
                                          wristDepthMeters: wristDepth,
                                          elbowDepthMeters: elbowDepth,
                                          widthPoints: palmScaleFinal * 0.62,
                                          direction2D: CGPoint(x: dir.x / dirLen, y: dir.y / dirLen))
            } else {
                palmDepth = filterDepth1D(key: key,
                                          value: Float(min(max(240.0 * 0.095 / Double(max(palmScaleFinal, 12)), 0.16), 1.40)),
                                          timestamp: timestamp)
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
            let facing = simd_dot(palmNormal, simd_float3(0, 0, 1)) * hand.chiralitySign

            // 6. Gestos.
            let thumb = joints2D[.thumbTip] ?? palmCenter
            let index = joints2D[.indexTip] ?? palmCenter
            let pinchPoint = CGPoint(x: (thumb.x + index.x) * 0.5, y: (thumb.y + index.y) * 0.5)
            let pinchWorld3D: simd_float3 = {
                if let t3 = worldJoints[.thumbTip], let i3 = worldJoints[.indexTip] {
                    return (t3 + i3) * 0.5
                }
                return .zero
            }()

            let ratio2D = hypot(thumb.x - index.x, thumb.y - index.y) / palmScaleFinal
            var pinch = min(max(1 - ratio2D / 0.9, 0), 1)

            if let t3 = cameraJoints[.thumbTip], let i3 = cameraJoints[.indexTip] {
                let metric = simd_distance(t3, i3)
                let metricPinch = min(max(1.0 - (metric - 0.008) / 0.030, 0.0), 1.0)
                pinch = max(pinch, CGFloat(metricPinch))
            }

            var keyConfidence: CGFloat = 1
            for name in [VNHumanHandPoseObservation.JointName.thumbTip, .indexTip, .middleMCP, .wrist] {
                if !hand.points.keys.contains(name) { keyConfidence = 0.5 }
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
                                  palmScale: palmScaleFinal))
        }

        return persistedPoses(seen: seen, timestamp: timestamp) + poses
    }

    /// Mantiene la última pose válida durante ~0.40 s para que la malla no parpadee
    /// ni desaparezca en micro-pérdidas (giros rápidos, puño, desenfoque de movimiento).
    private func persistedPoses(seen: Set<String>, timestamp: CFTimeInterval) -> [HandPose] {
        var out: [HandPose] = []
        for (key, stored) in lastPoses where !seen.contains(key) {
            if timestamp - (lastSeen[key] ?? 0) < 0.40 {
                out.append(stored)
            }
        }
        for key in lastPoses.keys where timestamp - (lastSeen[key] ?? 0) > 0.60 {
            lastPoses[key] = nil
            lastSeen[key] = nil
            filters2D[key] = nil
            filters3D[key] = nil
            depthFilters[key] = nil
            armFilters[key] = nil
        }
        return out
    }

    // MARK: - Completado cinemático

    /// Garantiza las 21 articulaciones **sin exigir la muñeca**. Es lo que evita que
    /// la mano desaparezca al cerrar el puño o cuando la muñeca sale del cuadro.
    static func completeMissingJoints(_ joints: inout [VNHumanHandPoseObservation.JointName: CGPoint],
                                      chiralityKey: String,
                                      fallbackCenter: CGPoint) {
        let mcpNames: [VNHumanHandPoseObservation.JointName] = [
            .indexMCP, .middleMCP, .ringMCP, .littleMCP
        ]

        if joints[.middleMCP] == nil {
            if let index = joints[.indexMCP], let ring = joints[.ringMCP] {
                joints[.middleMCP] = CGPoint(x: (index.x + ring.x) * 0.5,
                                             y: (index.y + ring.y) * 0.5)
            } else if let index = joints[.indexMCP] {
                joints[.middleMCP] = CGPoint(x: index.x + 28, y: index.y)
            } else if let ring = joints[.ringMCP] {
                joints[.middleMCP] = CGPoint(x: ring.x - 28, y: ring.y)
            } else if let little = joints[.littleMCP] {
                joints[.middleMCP] = CGPoint(x: little.x - 55, y: little.y)
            }
        }

        guard let middleMCP = joints[.middleMCP] ?? mcpNames.compactMap({ joints[$0] }).first else {
            if joints.isEmpty { joints[.wrist] = fallbackCenter }
            return
        }

        let breadth: CGFloat = {
            if let index = joints[.indexMCP], let little = joints[.littleMCP] {
                let d = hypot(index.x - little.x, index.y - little.y)
                if d > 8 { return d / 0.90 }
            }
            return 46
        }()

        // Dirección hacia los dedos: se ignoran los dedos doblados (puño).
        var fingerDirSum = CGPoint.zero
        var fingerDirCount = 0
        let fingerPairs: [(VNHumanHandPoseObservation.JointName,
                           VNHumanHandPoseObservation.JointName)] = [
            (.indexMCP, .indexTip), (.middleMCP, .middleTip),
            (.ringMCP, .ringTip), (.littleMCP, .littleTip)
        ]
        for (mcpName, tipName) in fingerPairs {
            guard let m = joints[mcpName], let t = joints[tipName] else { continue }
            let dx = t.x - m.x
            let dy = t.y - m.y
            let len = hypot(dx, dy)
            guard len > breadth * 0.22 else { continue }
            fingerDirSum.x += dx / len
            fingerDirSum.y += dy / len
            fingerDirCount += 1
        }

        var fingerDir: CGPoint
        if fingerDirCount > 0 {
            fingerDir = normalize(CGPoint(x: fingerDirSum.x / CGFloat(fingerDirCount),
                                          y: fingerDirSum.y / CGFloat(fingerDirCount)),
                                  fallback: CGPoint(x: 0, y: -1))
        } else if let wrist = joints[.wrist] {
            fingerDir = normalize(CGPoint(x: middleMCP.x - wrist.x, y: middleMCP.y - wrist.y),
                                  fallback: CGPoint(x: 0, y: -1))
        } else {
            fingerDir = CGPoint(x: 0, y: -1)
        }

        if joints[.wrist] == nil {
            joints[.wrist] = CGPoint(x: middleMCP.x - fingerDir.x * breadth,
                                     y: middleMCP.y - fingerDir.y * breadth)
        }
        guard let wrist = joints[.wrist] else { return }

        let palmDir = normalize(CGPoint(x: middleMCP.x - wrist.x, y: middleMCP.y - wrist.y),
                                fallback: fingerDir)
        let palmLength = max(hypot(middleMCP.x - wrist.x, middleMCP.y - wrist.y), breadth * 0.5)
        let lateral = CGPoint(x: -palmDir.y, y: palmDir.x)

        let mcpLayout: [(VNHumanHandPoseObservation.JointName, CGFloat)] = [
            (.indexMCP, -0.44), (.middleMCP, 0.0), (.ringMCP, 0.40), (.littleMCP, 0.80)
        ]
        for (name, offset) in mcpLayout where joints[name] == nil {
            joints[name] = CGPoint(x: wrist.x + palmDir.x * palmLength + lateral.x * breadth * offset,
                                   y: wrist.y + palmDir.y * palmLength + lateral.y * breadth * offset)
        }

        let chains: [[(VNHumanHandPoseObservation.JointName, CGFloat)]] = [
            [(.thumbCMC, 0.36), (.thumbMP, 0.34), (.thumbIP, 0.28), (.thumbTip, 0.24)],
            [(.indexMCP, 1.00), (.indexPIP, 0.50), (.indexDIP, 0.28), (.indexTip, 0.22)],
            [(.middleMCP, 1.00), (.middlePIP, 0.53), (.middleDIP, 0.29), (.middleTip, 0.23)],
            [(.ringMCP, 1.00), (.ringPIP, 0.49), (.ringDIP, 0.27), (.ringTip, 0.22)],
            [(.littleMCP, 1.00), (.littlePIP, 0.40), (.littleDIP, 0.23), (.littleTip, 0.19)]
        ]

        for chain in chains {
            var previous: CGPoint = (chain.first?.0 == .thumbCMC) ? wrist : (joints[chain[0].0] ?? wrist)
            for (index, entry) in chain.enumerated() {
                let (name, ratio) = entry
                if let existing = joints[name] {
                    previous = existing
                    continue
                }
                let step = max(palmLength * ratio, 6)
                let spread = (CGFloat(index) - 1.5) * 0.05
                let direction = normalize(CGPoint(x: palmDir.x + lateral.x * spread,
                                                  y: palmDir.y + lateral.y * spread),
                                          fallback: palmDir)
                let point = CGPoint(x: previous.x + direction.x * step,
                                    y: previous.y + direction.y * step)
                joints[name] = point
                previous = point
            }
        }
    }

    private static func normalize(_ p: CGPoint, fallback: CGPoint) -> CGPoint {
        let len = hypot(p.x, p.y)
        guard len > 1e-4 else { return fallback }
        return CGPoint(x: p.x / len, y: p.y / len)
    }

    // MARK: - Estabilización esqueletal

    /// Ningún hueso puede medir en pantalla más de lo que mide de verdad.
    static func enforceMaxBoneLengths(_ joints: inout [VNHumanHandPoseObservation.JointName: CGPoint],
                                      palmScale: CGFloat) {
        guard palmScale > 4 else { return }
        for link in HandDepthSampler.relativeBoneLengths {
            guard let parent = joints[link.parent], let child = joints[link.child] else { continue }
            let dx = child.x - parent.x
            let dy = child.y - parent.y
            let length = hypot(dx, dy)
            let maxLength = palmScale * CGFloat(link.ratio) * 1.30
            guard maxLength > 1, length > maxLength else { continue }
            let k = maxLength / length
            joints[link.child] = CGPoint(x: parent.x + dx * k, y: parent.y + dy * k)
        }
    }

    /// Rechaza saltos imposibles: la articulación se movió mucho más que la palma.
    static func rejectOutliers(_ joints: inout [VNHumanHandPoseObservation.JointName: CGPoint],
                               previous: HandPose?,
                               palmCenter: CGPoint,
                               palmScale: CGFloat) {
        guard let previous, palmScale > 4 else { return }
        let palmMoved = hypot(palmCenter.x - previous.palmCenter.x,
                              palmCenter.y - previous.palmCenter.y)
        // Si la mano entera se desplazó, el movimiento de un dedo es real.
        guard palmMoved < palmScale * 0.35 else { return }

        for name in Array(joints.keys) {
            guard let prev = previous.joints[name], let current = joints[name] else { continue }
            let moved = hypot(current.x - prev.x, current.y - prev.y)
            if moved > palmScale * 0.80 && moved > palmMoved * 3.0 {
                joints[name] = prev
            }
        }
    }

    private func updatePalmCalibration(key: String, observed: Float) {
        guard observed.isFinite, observed > 0.045, observed < 0.150 else { return }
        let samples = (palmCalibrationSamples[key] ?? 0) + 1
        palmCalibrationSamples[key] = samples
        if let current = palmCalibration[key] {
            let alpha: Float = samples < 40 ? 0.10 : 0.02
            palmCalibration[key] = current + (observed - current) * alpha
        } else {
            palmCalibration[key] = observed
        }
    }

    private static func collect(_ names: [VNHumanBodyPoseObservation.JointName],
                                from pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                                projector: ImageProjector) -> [CGPoint] {
        var out: [CGPoint] = []
        for name in names {
            guard let p = pts[name], p.confidence > 0.20 else { continue }
            out.append(projector.map(CGPoint(x: CGFloat(p.location.x), y: CGFloat(p.location.y))))
        }
        return out
    }

    private static func closest(to target: CGPoint, in candidates: [CGPoint], maxDistance: CGFloat) -> CGPoint? {
        var best: CGPoint?
        var bestDistance = maxDistance
        for candidate in candidates {
            let d = hypot(candidate.x - target.x, candidate.y - target.y)
            if d < bestDistance {
                bestDistance = d
                best = candidate
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
            let avgDepth = ((jointDepths[def.parent] ?? fallbackDepth)
                            + (jointDepths[def.child] ?? fallbackDepth)) * 0.5
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
        var filter = bank[name] ?? OneEuroFilter2D(minCutoff: 3.20, beta: 0.055, dCutoff: 1.0)
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
        var filter = bank[name] ?? OneEuroFilter3D(minCutoffXY: 3.00, betaXY: 3.20,
                                                   minCutoffZ: 2.00, betaZ: 2.40,
                                                   dCutoff: 1.0)
        let result = filter.filter(value, timestamp: timestamp)
        bank[name] = filter
        filters3D[key] = bank
        return result
    }

    private func filterDepth1D(key: String, value: Float, timestamp: CFTimeInterval) -> Float {
        var filter = depthFilters[key] ?? OneEuroFilter1D(minCutoff: 2.20, beta: 2.20, dCutoff: 1.0)
        let result = filter.filter(value, timestamp: timestamp)
        depthFilters[key] = filter
        return result
    }

    private func filterArmPoint(key: String, value: CGPoint, timestamp: CFTimeInterval) -> CGPoint {
        var filter = armFilters[key] ?? OneEuroFilter2D(minCutoff: 2.20, beta: 0.040, dCutoff: 1.0)
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
