import ARKit
import CoreVideo
import UIKit
import Vision
import simd

/// Fusión de **Apple Vision (Mano 21 pts + Cuerpo/Brazo) + Sensor LiDAR (`ARFrame.sceneDepth`)**.
///
/// - Extrae la profundidad métrica real (metros) de la palma, de las 21 articulaciones
///   y del **antebrazo/brazo (`Arm Tracking`)** desde el buffer Float32 del LiDAR.
/// - Escanea secciones transversales en el mapa LiDAR a partir de la muñeca para seguir
///   el ángulo y la profundidad real del antebrazo del usuario.
enum HandDepthSampler {

    /// Longitudes anatómicas relativas respecto de la distancia `wrist -> middleMCP` (~8.8 cm).
    private static let relativeBoneLengths: [(parent: VNHumanHandPoseObservation.JointName,
                                              child: VNHumanHandPoseObservation.JointName,
                                              ratio: Float)] = [
        // Pulgar
        (.wrist, .thumbCMC, 0.38),
        (.thumbCMC, .thumbMP, 0.46),
        (.thumbMP, .thumbIP, 0.36),
        (.thumbIP, .thumbTip, 0.30),
        // Índice
        (.wrist, .indexMCP, 0.98),
        (.indexMCP, .indexPIP, 0.45),
        (.indexPIP, .indexDIP, 0.28),
        (.indexDIP, .indexTip, 0.24),
        // Medio
        (.wrist, .middleMCP, 1.00),
        (.middleMCP, .middlePIP, 0.50),
        (.middlePIP, .middleDIP, 0.31),
        (.middleDIP, .middleTip, 0.25),
        // Anular
        (.wrist, .ringMCP, 0.94),
        (.ringMCP, .ringPIP, 0.46),
        (.ringPIP, .ringDIP, 0.29),
        (.ringDIP, .ringTip, 0.24),
        // Meñique
        (.wrist, .littleMCP, 0.86),
        (.littleMCP, .littlePIP, 0.36),
        (.littlePIP, .littleDIP, 0.23),
        (.littleDIP, .littleTip, 0.21)
    ]

    struct Forearm3D {
        let wrist2D: CGPoint
        let midForearm2D: CGPoint
        let elbow2D: CGPoint
        let wristDepthMeters: Float
        let elbowDepthMeters: Float
        let elbowCamera3D: simd_float3
        let elbowWorld3D: simd_float3
    }

    struct Reconstruction3D {
        let palmDepthMeters: Float
        let hasLiDAR: Bool
        let jointDepths: [VNHumanHandPoseObservation.JointName: Float]
        let cameraJoints: [VNHumanHandPoseObservation.JointName: simd_float3]
        let worldJoints: [VNHumanHandPoseObservation.JointName: simd_float3]
        let forearm: Forearm3D
    }

    /// Reconstruye las 21 articulaciones de la mano + el eje 3D del antebrazo (`Arm Tracking`)
    /// combinando Vision 2D, `VNDetectHumanBodyPoseRequest` (codo/muñeca) y el sensor LiDAR.
    static func reconstructHandAndArm3D(screenJoints: [VNHumanHandPoseObservation.JointName: CGPoint],
                                        visionElbow2D: CGPoint?,
                                        depthMap: CVPixelBuffer?,
                                        confidenceMap: CVPixelBuffer?,
                                        pose: CameraPose) -> Reconstruction3D {
        let viewport = pose.viewport
        let aspect = pose.imageAspect
        let orientation = pose.orientation

        let wristPt = screenJoints[.wrist] ?? CGPoint(x: viewport.width * 0.5, y: viewport.height * 0.8)
        let middlePt = screenJoints[.middleMCP] ?? CGPoint(x: wristPt.x, y: wristPt.y - 60)
        let palmPixels = max(hypot(wristPt.x - middlePt.x, wristPt.y - middlePt.y), 14.0)

        // 1. Estimación métrica por tamaño aparente de la palma (respaldo si no hay LiDAR).
        let focal = Float(max((pose.focalX + pose.focalY) * 0.5, 240.0))
        let apparentPalmDepth = min(max((focal * 0.088) / Float(palmPixels), 0.15), 1.45)

        var rawJointSamples: [VNHumanHandPoseObservation.JointName: Float] = [:]
        var palmCandidates: [Float] = []

        // Dirección anatómica base del antebrazo (desde el centro de nudillos hacia la muñeca).
        let knuckleCenter: CGPoint = {
            let pts = [
                screenJoints[.indexMCP],
                screenJoints[.middleMCP],
                screenJoints[.ringMCP],
                screenJoints[.littleMCP]
            ].compactMap { $0 }
            guard !pts.isEmpty else { return middlePt }
            let sx = pts.reduce(CGFloat(0)) { $0 + $1.x }
            let sy = pts.reduce(CGFloat(0)) { $0 + $1.y }
            return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
        }()

        var baseArmDir = CGPoint(x: wristPt.x - knuckleCenter.x, y: wristPt.y - knuckleCenter.y)
        let baseArmLen = max(hypot(baseArmDir.x, baseArmDir.y), 0.001)
        baseArmDir.x /= baseArmLen
        baseArmDir.y /= baseArmLen

        // Si Vision Body Pose detectó el codo real, fusionamos su dirección con el eje anatómico.
        if let elbow = visionElbow2D {
            let dx = elbow.x - wristPt.x
            let dy = elbow.y - wristPt.y
            let dist = hypot(dx, dy)
            if dist > palmPixels * 0.4 && dist < palmPixels * 4.5 {
                let bodyDir = CGPoint(x: dx / dist, y: dy / dist)
                // Sólo aceptar si apunta en el mismo hemisferio que la muñeca (producto escalar > 0.15).
                if baseArmDir.x * bodyDir.x + baseArmDir.y * bodyDir.y > 0.15 {
                    baseArmDir = CGPoint(x: baseArmDir.x * 0.35 + bodyDir.x * 0.65,
                                         y: baseArmDir.y * 0.35 + bodyDir.y * 0.65)
                    let norm = max(hypot(baseArmDir.x, baseArmDir.y), 0.001)
                    baseArmDir.x /= norm
                    baseArmDir.y /= norm
                }
            }
        }

        let forearmLength = palmPixels * 1.65
        var tracedMidForearm2D = CGPoint(x: wristPt.x + baseArmDir.x * (forearmLength * 0.5),
                                         y: wristPt.y + baseArmDir.y * (forearmLength * 0.5))
        var tracedElbow2D = CGPoint(x: wristPt.x + baseArmDir.x * forearmLength,
                                    y: wristPt.y + baseArmDir.y * forearmLength)
        var tracedElbowDepth: Float?

        if let depthMap {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
            defer {
                if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            }

            let palmAnchorNames: [VNHumanHandPoseObservation.JointName] = [
                .wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP, .thumbCMC
            ]

            for name in palmAnchorNames {
                if let pt = screenJoints[name],
                   let d = sampleLockedDepth(at: pt,
                                             depthMap: depthMap,
                                             confidenceMap: confidenceMap,
                                             imageAspect: aspect,
                                             viewport: viewport,
                                             orientation: orientation,
                                             referenceDepth: nil) {
                    palmCandidates.append(d)
                }
            }

            let center = CGPoint(x: (wristPt.x + middlePt.x) * 0.5, y: (wristPt.y + middlePt.y) * 0.5)
            if let d = sampleLockedDepth(at: center,
                                         depthMap: depthMap,
                                         confidenceMap: confidenceMap,
                                         imageAspect: aspect,
                                         viewport: viewport,
                                         orientation: orientation,
                                         referenceDepth: nil) {
                palmCandidates.append(d)
            }

            palmCandidates.sort()
            let lidarPalmDepth: Float? = palmCandidates.isEmpty
                ? nil
                : palmCandidates[max(0, min(palmCandidates.count - 1, palmCandidates.count / 3))]

            if let refDepth = lidarPalmDepth {
                for (name, pt) in screenJoints {
                    if let d = sampleLockedDepth(at: pt,
                                                 depthMap: depthMap,
                                                 confidenceMap: confidenceMap,
                                                 imageAspect: aspect,
                                                 viewport: viewport,
                                                 orientation: orientation,
                                                 referenceDepth: refDepth) {
                        rawJointSamples[name] = d
                    }
                }

                // Rastreo LiDAR del antebrazo (Arm Tracking): escanea secciones transversales
                // desde la muñeca hacia el codo para localizar el cilindro real del brazo en 3D.
                let wristRef = rawJointSamples[.wrist] ?? refDepth
                let armTrace = traceLockedForearmInLiDAR(wrist: wristPt,
                                                         initialDir: baseArmDir,
                                                         palmScale: palmPixels,
                                                         wristDepth: wristRef,
                                                         depthMap: depthMap,
                                                         confidenceMap: confidenceMap,
                                                         imageAspect: aspect,
                                                         viewport: viewport,
                                                         orientation: orientation)
                tracedMidForearm2D = armTrace.midPoint
                tracedElbow2D = armTrace.endPoint
                tracedElbowDepth = armTrace.endDepth
            }
        }

        let hasLiDAR = !palmCandidates.isEmpty
        let anchorDepth: Float = {
            if hasLiDAR {
                let rawLidar = palmCandidates[max(0, min(palmCandidates.count - 1, palmCandidates.count / 3))]
                return min(max(rawLidar, 0.12), 1.80)
            }
            return apparentPalmDepth
        }()

        // 2. Asignar y restringir anatómica y cinemáticamente la profundidad Z de cada hueso.
        var jointDepths: [VNHumanHandPoseObservation.JointName: Float] = [:]
        jointDepths[.wrist] = rawJointSamples[.wrist].map { clampNear($0, ref: anchorDepth, maxDelta: 0.06) } ?? anchorDepth

        let baseMetricPalm: Float = 0.088

        for link in relativeBoneLengths {
            guard let childPt = screenJoints[link.child] else { continue }
            let parentDepth = jointDepths[link.parent] ?? anchorDepth
            let maxBoneMeters = baseMetricPalm * link.ratio * 1.35

            if let sampled = rawJointSamples[link.child],
               abs(sampled - parentDepth) <= maxBoneMeters {
                jointDepths[link.child] = parentDepth * 0.25 + sampled * 0.75
            } else if let parentPt = screenJoints[link.parent] {
                let dxMeters = (Float(childPt.x - parentPt.x) / focal) * parentDepth
                let dyMeters = (Float(childPt.y - parentPt.y) / focal) * parentDepth
                let planarSq = dxMeters * dxMeters + dyMeters * dyMeters
                let nominalLen = baseMetricPalm * link.ratio
                let dz = sqrt(max(0.0, nominalLen * nominalLen - min(planarSq, nominalLen * nominalLen)))
                let inferred = parentDepth - dz * 0.35
                jointDepths[link.child] = clampNear(inferred, ref: anchorDepth, maxDelta: 0.14)
            } else {
                jointDepths[link.child] = parentDepth
            }
        }

        for (name, _) in screenJoints where jointDepths[name] == nil {
            jointDepths[name] = anchorDepth
        }

        // 3. Desproyectar las 21 articulaciones + el antebrazo al espacio 3D de cámara y mundo.
        var cameraJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
        var worldJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]

        for (name, pt) in screenJoints {
            let d = jointDepths[name] ?? anchorDepth
            let cam3D = pose.unprojectToCamera(screenPoint: pt, depth: d)
            cameraJoints[name] = cam3D
            worldJoints[name] = pose.cameraToWorld(cam3D)
        }

        let wristDepthFinal = jointDepths[.wrist] ?? anchorDepth
        let elbowDepthFinal = tracedElbowDepth ?? min(wristDepthFinal + 0.04, 1.85)
        let elbowCam3D = pose.unprojectToCamera(screenPoint: tracedElbow2D, depth: elbowDepthFinal)
        let elbowWorld3D = pose.cameraToWorld(elbowCam3D)

        let forearm = Forearm3D(wrist2D: wristPt,
                                midForearm2D: tracedMidForearm2D,
                                elbow2D: tracedElbow2D,
                                wristDepthMeters: wristDepthFinal,
                                elbowDepthMeters: elbowDepthFinal,
                                elbowCamera3D: elbowCam3D,
                                elbowWorld3D: elbowWorld3D)

        return Reconstruction3D(palmDepthMeters: anchorDepth,
                                hasLiDAR: hasLiDAR,
                                jointDepths: jointDepths,
                                cameraJoints: cameraJoints,
                                worldJoints: worldJoints,
                                forearm: forearm)
    }

    // MARK: - Rastreo Transversal del Antebrazo sobre el Mapa de Profundidad LiDAR

    private static func traceLockedForearmInLiDAR(wrist: CGPoint,
                                                  initialDir: CGPoint,
                                                  palmScale: CGFloat,
                                                  wristDepth: Float,
                                                  depthMap: CVPixelBuffer,
                                                  confidenceMap: CVPixelBuffer?,
                                                  imageAspect: CGFloat,
                                                  viewport: CGSize,
                                                  orientation: UIInterfaceOrientation)
        -> (midPoint: CGPoint, endPoint: CGPoint, endDepth: Float) {

        var currentDir = initialDir
        let perp = CGPoint(x: -currentDir.y, y: currentDir.x)
        let totalLen = palmScale * 1.65

        var midPoint = CGPoint(x: wrist.x + currentDir.x * (totalLen * 0.5),
                               y: wrist.y + currentDir.y * (totalLen * 0.5))
        var endDepth = wristDepth

        // Muestreamos dos secciones transversales (a 0.55x y 1.15x del tamaño de palma desde la muñeca)
        // para encontrar el centro de masa real del antebrazo en el mapa LiDAR.
        for (stepIdx, distFactor) in [CGFloat(0.55), CGFloat(1.15)].enumerated() {
            let centerSample = CGPoint(x: wrist.x + currentDir.x * (palmScale * distFactor),
                                       y: wrist.y + currentDir.y * (palmScale * distFactor))
            var weightedOffset: CGFloat = 0
            var weightSum: CGFloat = 0
            var depthAccum: Float = 0
            var depthCount: Float = 0

            for offsetStep in -3...3 {
                let lateral = CGFloat(offsetStep) * (palmScale * 0.11)
                let probe = CGPoint(x: centerSample.x + perp.x * lateral,
                                    y: centerSample.y + perp.y * lateral)
                if let d = sampleLockedDepth(at: probe,
                                             depthMap: depthMap,
                                             confidenceMap: confidenceMap,
                                             imageAspect: imageAspect,
                                             viewport: viewport,
                                             orientation: orientation,
                                             referenceDepth: nil),
                   d >= wristDepth - 0.14 && d <= wristDepth + 0.22 {
                    let w: CGFloat = 1.0
                    weightedOffset += lateral * w
                    weightSum += w
                    depthAccum += d
                    depthCount += 1
                }
            }

            if weightSum >= 2.0 {
                let shift = (weightedOffset / weightSum) * 0.55
                let refinedPt = CGPoint(x: centerSample.x + perp.x * shift,
                                        y: centerSample.y + perp.y * shift)
                let dx = refinedPt.x - wrist.x
                let dy = refinedPt.y - wrist.y
                let len = max(hypot(dx, dy), 0.001)
                currentDir = CGPoint(x: currentDir.x * 0.45 + (dx / len) * 0.55,
                                     y: currentDir.y * 0.45 + (dy / len) * 0.55)
                let norm = max(hypot(currentDir.x, currentDir.y), 0.001)
                currentDir.x /= norm
                currentDir.y /= norm

                if stepIdx == 0 {
                    midPoint = refinedPt
                }
                if depthCount > 0 {
                    endDepth = depthAccum / depthCount
                }
            }
        }

        let endPoint = CGPoint(x: wrist.x + currentDir.x * totalLen,
                               y: wrist.y + currentDir.y * totalLen)
        midPoint = CGPoint(x: (wrist.x + endPoint.x) * 0.5,
                           y: (wrist.y + endPoint.y) * 0.5)
        return (midPoint, endPoint, endDepth)
    }

    // MARK: - Muestreo interno 3x3 sobre el buffer LiDAR

    private static func clampNear(_ value: Float, ref: Float, maxDelta: Float) -> Float {
        min(max(value, ref - maxDelta), ref + maxDelta)
    }

    private static func sampleLockedDepth(at point: CGPoint,
                                          depthMap: CVPixelBuffer,
                                          confidenceMap: CVPixelBuffer?,
                                          imageAspect: CGFloat,
                                          viewport: CGSize,
                                          orientation: UIInterfaceOrientation,
                                          referenceDepth: Float?) -> Float? {
        guard imageAspect > 0.1, viewport.width > 1, viewport.height > 1 else { return nil }

        let scale = max(viewport.width / imageAspect, viewport.height)
        let drawnWidth = imageAspect * scale
        let normalizedX = (point.x - (viewport.width - drawnWidth) / 2) / drawnWidth
        let normalizedY = 1 - (point.y - (viewport.height - scale) / 2) / scale
        guard normalizedX >= 0, normalizedX <= 1,
              normalizedY >= 0, normalizedY <= 1 else { return nil }

        var bufferX = normalizedX
        var bufferY = normalizedY
        if orientation == .landscapeLeft {
            bufferX = 1 - normalizedX
            bufferY = 1 - normalizedY
        }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard width > 2, height > 2 else { return nil }

        let centerX = min(max(Int(bufferX * CGFloat(width)), 0), width - 1)
        let centerY = min(max(Int((1 - bufferY) * CGFloat(height)), 0), height - 1)

        let confBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confWidth = confidenceMap.map { CVPixelBufferGetWidth($0) } ?? 0
        let confHeight = confidenceMap.map { CVPixelBufferGetHeight($0) } ?? 0
        let confRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        var samples: [Float] = []
        samples.reserveCapacity(9)

        for dy in -1...1 {
            let y = min(max(centerY + dy, 0), height - 1)
            for dx in -1...1 {
                let x = min(max(centerX + dx, 0), width - 1)

                if let confBase, confWidth == width, confHeight == height {
                    let confPtr = confBase.advanced(by: y * confRowBytes + x)
                    let conf = confPtr.assumingMemoryBound(to: UInt8.self).pointee
                    if conf == 0 { continue }
                }

                let ptr = base.advanced(by: y * rowBytes + x * 4)
                let meters = ptr.assumingMemoryBound(to: Float32.self).pointee
                guard meters.isFinite, meters > 0.10, meters < 2.20 else { continue }

                if let ref = referenceDepth {
                    guard meters >= ref - 0.18, meters <= ref + 0.15 else { continue }
                }
                samples.append(meters)
            }
        }

        if samples.isEmpty {
            let ptr = base.advanced(by: centerY * rowBytes + centerX * 4)
            let meters = ptr.assumingMemoryBound(to: Float32.self).pointee
            if meters.isFinite, meters > 0.10, meters < 2.20 {
                if let ref = referenceDepth {
                    if meters >= ref - 0.18 && meters <= ref + 0.15 {
                        return meters
                    }
                    return nil
                }
                return meters
            }
            return nil
        }

        samples.sort()
        return samples[max(0, samples.count / 3)]
    }
}
