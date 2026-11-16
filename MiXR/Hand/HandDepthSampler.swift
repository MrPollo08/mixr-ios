import ARKit
import CoreVideo
import UIKit
import Vision
import simd

/// Fusión de **Apple Vision (Mano 21 pts + Cuerpo/Brazo) + Sensor LiDAR (`ARFrame.sceneDepth`)**.
///
/// - Extrae la profundidad métrica real (metros) de la palma, de las 21 articulaciones
///   y del **antebrazo (`Arm Tracking`)** desde el buffer Float32 del LiDAR.
/// - Escanea secciones transversales en el mapa LiDAR a partir de la muñeca para seguir
///   el ángulo y la profundidad real del antebrazo.
/// - Acepta una **calibración métrica de la palma** (medida del usuario con LiDAR) para
///   que la inferencia de profundidad de los dedos use su mano real, no una media.
enum HandDepthSampler {

    /// Longitudes anatómicas relativas respecto de `wrist -> middleMCP` (palma ≈ 9.5 cm).
    static let relativeBoneLengths: [(parent: VNHumanHandPoseObservation.JointName,
                                      child: VNHumanHandPoseObservation.JointName,
                                      ratio: Float)] = [
        (.wrist, .thumbCMC, 0.34),
        (.thumbCMC, .thumbMP, 0.30),
        (.thumbMP, .thumbIP, 0.24),
        (.thumbIP, .thumbTip, 0.19),

        (.wrist, .indexMCP, 1.00),
        (.indexMCP, .indexPIP, 0.48),
        (.indexPIP, .indexDIP, 0.27),
        (.indexDIP, .indexTip, 0.22),

        (.wrist, .middleMCP, 1.00),
        (.middleMCP, .middlePIP, 0.52),
        (.middlePIP, .middleDIP, 0.29),
        (.middleDIP, .middleTip, 0.23),

        (.wrist, .ringMCP, 0.95),
        (.ringMCP, .ringPIP, 0.49),
        (.ringPIP, .ringDIP, 0.27),
        (.ringDIP, .ringTip, 0.22),

        (.wrist, .littleMCP, 0.86),
        (.littleMCP, .littlePIP, 0.36),
        (.littlePIP, .littleDIP, 0.21),
        (.littleDIP, .littleTip, 0.18)
    ]

    struct Forearm3D {
        let wrist2D: CGPoint
        let midForearm2D: CGPoint
        let elbow2D: CGPoint
        let wristDepthMeters: Float
        let elbowDepthMeters: Float
        let elbowCamera3D: simd_float3
        let elbowWorld3D: simd_float3
        /// true si el codo viene de Vision Body Pose (no de la extensión al borde).
        let elbowFromBody: Bool
    }

    struct Reconstruction3D {
        let palmDepthMeters: Float
        let hasLiDAR: Bool
        /// Longitud métrica estimada de la palma (muñeca → nudillo medio), en metros.
        let estimatedPalmMeters: Float
        let jointDepths: [VNHumanHandPoseObservation.JointName: Float]
        let cameraJoints: [VNHumanHandPoseObservation.JointName: simd_float3]
        let worldJoints: [VNHumanHandPoseObservation.JointName: simd_float3]
        let forearm: Forearm3D
    }

    static func reconstructHandAndArm3D(screenJoints: [VNHumanHandPoseObservation.JointName: CGPoint],
                                        visionElbow2D: CGPoint?,
                                        depthMap: CVPixelBuffer?,
                                        confidenceMap: CVPixelBuffer?,
                                        metricPalmMeters: Float,
                                        pose: CameraPose) -> Reconstruction3D {
        let viewport = pose.viewport
        let aspect = pose.imageAspect
        let orientation = pose.orientation

        let wristPt = screenJoints[.wrist] ?? CGPoint(x: viewport.width * 0.5, y: viewport.height * 0.8)
        let middlePt = screenJoints[.middleMCP] ?? CGPoint(x: wristPt.x, y: wristPt.y - 60)
        let palmPixels = max(hypot(wristPt.x - middlePt.x, wristPt.y - middlePt.y), 12.0)

        // Tamaño real de la palma del usuario (calibrado con LiDAR, con respaldo antropométrico).
        let realPalm = clamp(metricPalmMeters, 0.060, 0.130)

        let focal = Float(max((pose.focalX + pose.focalY) * 0.5, 240.0))
        // Distancia estimada sólo por tamaño aparente (respaldo cuando no hay LiDAR).
        let apparentPalmDepth = clamp((focal * realPalm) / Float(palmPixels), 0.14, 1.50)

        var rawJointSamples: [VNHumanHandPoseObservation.JointName: Float] = [:]
        var palmCandidates: [Float] = []

        // Eje anatómico del antebrazo (nudillos → muñeca).
        let knuckleCenter = averagePoint([
            screenJoints[.indexMCP], screenJoints[.middleMCP],
            screenJoints[.ringMCP], screenJoints[.littleMCP]
        ]) ?? middlePt

        var baseArmDir = CGPoint(x: wristPt.x - knuckleCenter.x, y: wristPt.y - knuckleCenter.y)
        baseArmDir = normalizePoint(baseArmDir, fallback: CGPoint(x: 0, y: 1))

        // Codo de Vision Body Pose: sólo se acepta si apunta en el mismo hemisferio.
        var elbowFromBody = false
        if let elbow = visionElbow2D {
            let dx = elbow.x - wristPt.x
            let dy = elbow.y - wristPt.y
            let dist = hypot(dx, dy)
            if dist > palmPixels * 0.45 && dist < palmPixels * 5.0 {
                let bodyDir = CGPoint(x: dx / dist, y: dy / dist)
                if baseArmDir.x * bodyDir.x + baseArmDir.y * bodyDir.y > 0.30 {
                    baseArmDir = normalizePoint(CGPoint(x: baseArmDir.x * 0.30 + bodyDir.x * 0.70,
                                                        y: baseArmDir.y * 0.30 + bodyDir.y * 0.70),
                                                fallback: baseArmDir)
                    elbowFromBody = true
                }
            }
        }

        // Sin codo: el antebrazo continúa hasta el borde del cuadro (nunca corta en el aire).
        var elbow2D: CGPoint
        let minArmLen = palmPixels * 1.15
        let maxArmLen = palmPixels * 3.2
        if elbowFromBody, let elbow = visionElbow2D {
            let dx = elbow.x - wristPt.x
            let dy = elbow.y - wristPt.y
            let len = max(hypot(dx, dy), minArmLen)
            elbow2D = CGPoint(x: wristPt.x + baseArmDir.x * min(len, maxArmLen),
                              y: wristPt.y + baseArmDir.y * min(len, maxArmLen))
        } else {
            let edge = intersectViewport(from: wristPt, direction: baseArmDir, viewport: viewport)
            let len = clamp(Float(edge), Float(minArmLen), Float(maxArmLen))
            elbow2D = CGPoint(x: wristPt.x + baseArmDir.x * CGFloat(len),
                              y: wristPt.y + baseArmDir.y * CGFloat(len))
        }

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

                // Rastreo transversal del antebrazo en el mapa de profundidad.
                let armTrace = traceLockedForearm(wrist: wristPt,
                                                  initialDir: baseArmDir,
                                                  endPoint: elbow2D,
                                                  palmScale: palmPixels,
                                                  wristDepth: rawJointSamples[.wrist] ?? refDepth,
                                                  depthMap: depthMap,
                                                  confidenceMap: confidenceMap,
                                                  imageAspect: aspect,
                                                  viewport: viewport,
                                                  orientation: orientation)
                tracedElbowDepth = armTrace.endDepth
                if !elbowFromBody { elbow2D = armTrace.endPoint }
            }
        }

        let hasLiDAR = !palmCandidates.isEmpty
        let anchorDepth: Float = {
            if hasLiDAR {
                let rawLidar = palmCandidates[max(0, min(palmCandidates.count - 1, palmCandidates.count / 3))]
                return clamp(rawLidar, 0.12, 1.80)
            }
            return apparentPalmDepth
        }()

        // Calibración observada: conocemos los píxeles de la palma y su profundidad.
        let observedPalmMeters = clamp((Float(palmPixels) / focal) * anchorDepth, 0.050, 0.150)

        // Profundidades articulación por articulación con restricciones cinemáticas.
        var jointDepths: [VNHumanHandPoseObservation.JointName: Float] = [:]
        jointDepths[.wrist] = rawJointSamples[.wrist].map { clampNear($0, ref: anchorDepth, maxDelta: 0.05) } ?? anchorDepth

        for link in relativeBoneLengths {
            guard let childPt = screenJoints[link.child] else { continue }
            let parentDepth = jointDepths[link.parent] ?? anchorDepth
            let nominalLen = realPalm * link.ratio
            let maxBoneMeters = nominalLen * 1.45

            if let sampled = rawJointSamples[link.child],
               abs(sampled - parentDepth) <= maxBoneMeters {
                jointDepths[link.child] = parentDepth * 0.30 + sampled * 0.70
            } else if let parentPt = screenJoints[link.parent] {
                // Sin lectura válida del LiDAR (dedo fino / fondo brillante): se infiere
                // el escorzo 3D con la longitud anatómica real del hueso.
                let dxMeters = (Float(childPt.x - parentPt.x) / focal) * parentDepth
                let dyMeters = (Float(childPt.y - parentPt.y) / focal) * parentDepth
                let planarSq = dxMeters * dxMeters + dyMeters * dyMeters
                let dz = sqrt(max(0.0, nominalLen * nominalLen - min(planarSq, nominalLen * nominalLen)))
                // Las falanges distales tienden a arquearse hacia la cámara.
                let curl: Float = link.ratio < 0.30 ? 0.30 : 0.12
                let inferred = parentDepth - dz * curl
                jointDepths[link.child] = clampNear(inferred, ref: anchorDepth, maxDelta: 0.16)
            } else {
                jointDepths[link.child] = parentDepth
            }
        }

        for (name, _) in screenJoints where jointDepths[name] == nil {
            jointDepths[name] = anchorDepth
        }

        var cameraJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
        var worldJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
        for (name, pt) in screenJoints {
            let d = jointDepths[name] ?? anchorDepth
            let cam3D = pose.unprojectToCamera(screenPoint: pt, depth: d)
            cameraJoints[name] = cam3D
            worldJoints[name] = pose.cameraToWorld(cam3D)
        }

        let wristDepthFinal = jointDepths[.wrist] ?? anchorDepth
        let elbowDepthFinal = tracedElbowDepth ?? min(wristDepthFinal + 0.05, 1.85)
        let elbowCam3D = pose.unprojectToCamera(screenPoint: elbow2D, depth: elbowDepthFinal)

        let forearm = Forearm3D(wrist2D: wristPt,
                                midForearm2D: CGPoint(x: (wristPt.x + elbow2D.x) * 0.5,
                                                      y: (wristPt.y + elbow2D.y) * 0.5),
                                elbow2D: elbow2D,
                                wristDepthMeters: wristDepthFinal,
                                elbowDepthMeters: elbowDepthFinal,
                                elbowCamera3D: elbowCam3D,
                                elbowWorld3D: pose.cameraToWorld(elbowCam3D),
                                elbowFromBody: elbowFromBody)

        return Reconstruction3D(palmDepthMeters: anchorDepth,
                                hasLiDAR: hasLiDAR,
                                estimatedPalmMeters: observedPalmMeters,
                                jointDepths: jointDepths,
                                cameraJoints: cameraJoints,
                                worldJoints: worldJoints,
                                forearm: forearm)
    }

    // MARK: - Antebrazo en el mapa de profundidad

    private static func traceLockedForearm(wrist: CGPoint,
                                           initialDir: CGPoint,
                                           endPoint: CGPoint,
                                           palmScale: CGFloat,
                                           wristDepth: Float,
                                           depthMap: CVPixelBuffer,
                                           confidenceMap: CVPixelBuffer?,
                                           imageAspect: CGFloat,
                                           viewport: CGSize,
                                           orientation: UIInterfaceOrientation)
        -> (endPoint: CGPoint, endDepth: Float) {

        let totalLen = hypot(endPoint.x - wrist.x, endPoint.y - wrist.y)
        guard totalLen > palmScale * 0.6 else { return (endPoint, wristDepth) }

        var dir = initialDir
        var perp = CGPoint(x: -dir.y, y: dir.x)
        var bestEnd = endPoint
        var bestDepth = wristDepth

        for distFactor in [CGFloat(0.55), CGFloat(1.05), CGFloat(1.55)] {
            let probeDist = palmScale * distFactor
            guard probeDist < totalLen else { break }
            let center = CGPoint(x: wrist.x + dir.x * probeDist,
                                 y: wrist.y + dir.y * probeDist)

            var weightedOffset: CGFloat = 0
            var weightSum: CGFloat = 0
            var depthAccum: Float = 0
            var depthCount: Float = 0

            for step in -4...4 {
                let lateral = CGFloat(step) * (palmScale * 0.085)
                let probe = CGPoint(x: center.x + perp.x * lateral,
                                    y: center.y + perp.y * lateral)
                if let d = sampleLockedDepth(at: probe,
                                             depthMap: depthMap,
                                             confidenceMap: confidenceMap,
                                             imageAspect: imageAspect,
                                             viewport: viewport,
                                             orientation: orientation,
                                             referenceDepth: nil),
                   d >= wristDepth - 0.18 && d <= wristDepth + 0.26 {
                    weightedOffset += lateral
                    weightSum += 1
                    depthAccum += d
                    depthCount += 1
                }
            }

            if weightSum >= 3 {
                let shift = (weightedOffset / weightSum) * 0.45
                let refined = CGPoint(x: center.x + perp.x * shift, y: center.y + perp.y * shift)
                dir = normalizePoint(CGPoint(x: dir.x * 0.55 + (refined.x - wrist.x) * 0.45,
                                             y: dir.y * 0.55 + (refined.y - wrist.y) * 0.45),
                                     fallback: dir)
                perp = CGPoint(x: -dir.y, y: dir.x)
                bestDepth = depthAccum / depthCount
            }
        }

        bestEnd = CGPoint(x: wrist.x + dir.x * totalLen, y: wrist.y + dir.y * totalLen)
        return (bestEnd, bestDepth)
    }

    // MARK: - Utilidades

    private static func averagePoint(_ points: [CGPoint?]) -> CGPoint? {
        let valid = points.compactMap { $0 }
        guard !valid.isEmpty else { return nil }
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        for pt in valid { sx += pt.x; sy += pt.y }
        return CGPoint(x: sx / CGFloat(valid.count), y: sy / CGFloat(valid.count))
    }

    private static func normalizePoint(_ p: CGPoint, fallback: CGPoint) -> CGPoint {
        let len = hypot(p.x, p.y)
        guard len > 1e-4 else { return fallback }
        return CGPoint(x: p.x / len, y: p.y / len)
    }

    /// Distancia (en puntos) desde `origin` hasta el borde del viewport a lo largo de `dir`.
    private static func intersectViewport(from origin: CGPoint,
                                          direction: CGPoint,
                                          viewport: CGSize) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        if abs(direction.x) > 1e-4 {
            let t1 = (0 - origin.x) / direction.x
            let t2 = (viewport.width - origin.x) / direction.x
            for t in [t1, t2] where t > 1 { best = min(best, t) }
        }
        if abs(direction.y) > 1e-4 {
            let t1 = (0 - origin.y) / direction.y
            let t2 = (viewport.height - origin.y) / direction.y
            for t in [t1, t2] where t > 1 { best = min(best, t) }
        }
        return best.isFinite ? best : 200
    }

    private static func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
        min(max(value, low), high)
    }

    private static func clampNear(_ value: Float, ref: Float, maxDelta: Float) -> Float {
        min(max(value, ref - maxDelta), ref + maxDelta)
    }

    // MARK: - Muestreo 3x3 sobre el buffer LiDAR

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
                    if confPtr.assumingMemoryBound(to: UInt8.self).pointee == 0 { continue }
                }

                let ptr = base.advanced(by: y * rowBytes + x * 4)
                let meters = ptr.assumingMemoryBound(to: Float32.self).pointee
                guard meters.isFinite, meters > 0.10, meters < 2.30 else { continue }

                if let ref = referenceDepth {
                    guard meters >= ref - 0.20, meters <= ref + 0.16 else { continue }
                }
                samples.append(meters)
            }
        }

        if samples.isEmpty {
            let ptr = base.advanced(by: centerY * rowBytes + centerX * 4)
            let meters = ptr.assumingMemoryBound(to: Float32.self).pointee
            guard meters.isFinite, meters > 0.10, meters < 2.30 else { return nil }
            if let ref = referenceDepth {
                return (meters >= ref - 0.20 && meters <= ref + 0.16) ? meters : nil
            }
            return meters
        }

        samples.sort()
        return samples[max(0, samples.count / 3)]
    }
}
