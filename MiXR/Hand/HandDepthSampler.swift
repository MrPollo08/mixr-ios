import ARKit
import CoreVideo
import UIKit
import Vision
import simd

/// Fusión de **Apple Vision (21 articulaciones) + Sensor LiDAR (`ARFrame.sceneDepth`)**.
///
/// Extrae la profundidad métrica real (metros) de la palma y de cada una de las
/// 21 articulaciones desde el buffer Float32 del LiDAR, filtra el bleeding del
/// fondo en los bordes de los dedos y reconstruye el esqueleto 3D completo en
/// el espacio de la cámara y del mundo.
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

    struct Reconstruction3D {
        let palmDepthMeters: Float
        let hasLiDAR: Bool
        let jointDepths: [VNHumanHandPoseObservation.JointName: Float]
        let cameraJoints: [VNHumanHandPoseObservation.JointName: simd_float3]
        let worldJoints: [VNHumanHandPoseObservation.JointName: simd_float3]
    }

    /// Reconstruye las 21 articulaciones en 3D combinando los puntos 2D, el mapa
    /// de profundidad del LiDAR (si está disponible) y restricciones cinemáticas.
    static func reconstructHand3D(screenJoints: [VNHumanHandPoseObservation.JointName: CGPoint],
                                  depthMap: CVPixelBuffer?,
                                  confidenceMap: CVPixelBuffer?,
                                  pose: CameraPose) -> Reconstruction3D {
        let viewport = pose.viewport
        let aspect = pose.imageAspect
        let orientation = pose.orientation

        // 1. Estimación métrica por tamaño aparente de la palma (respaldo si no hay LiDAR
        //    o si la mano sale del rango de 0.12m..2.2m del sensor).
        let apparentPalmDepth: Float = {
            guard let wrist = screenJoints[.wrist],
                  let middle = screenJoints[.middleMCP] else { return 0.42 }
            let palmPixels = max(Float(hypot(wrist.x - middle.x, wrist.y - middle.y)), 12.0)
            let focal = Float(max((pose.focalX + pose.focalY) * 0.5, 240.0))
            // Una palma adulta media mide ~0.088 m desde la muñeca al nudillo medio.
            let estimated = (focal * 0.088) / palmPixels
            return min(max(estimated, 0.16), 1.40)
        }()

        var rawJointSamples: [VNHumanHandPoseObservation.JointName: Float] = [:]
        var palmCandidates: [Float] = []

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

            if let wrist = screenJoints[.wrist], let middle = screenJoints[.middleMCP] {
                let center = CGPoint(x: (wrist.x + middle.x) * 0.5, y: (wrist.y + middle.y) * 0.5)
                if let d = sampleLockedDepth(at: center,
                                             depthMap: depthMap,
                                             confidenceMap: confidenceMap,
                                             imageAspect: aspect,
                                             viewport: viewport,
                                             orientation: orientation,
                                             referenceDepth: nil) {
                    palmCandidates.append(d)
                }
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

        let focal = Float(max((pose.focalX + pose.focalY) * 0.5, 240.0))
        let baseMetricPalm: Float = 0.088

        for link in relativeBoneLengths {
            guard let childPt = screenJoints[link.child] else { continue }
            let parentDepth = jointDepths[link.parent] ?? anchorDepth
            let maxBoneMeters = baseMetricPalm * link.ratio * 1.35

            if let sampled = rawJointSamples[link.child],
               abs(sampled - parentDepth) <= maxBoneMeters {
                // Fusión suave: 75% lectura directa LiDAR del hueso + 25% continuidad del padre.
                jointDepths[link.child] = parentDepth * 0.25 + sampled * 0.75
            } else if let parentPt = screenJoints[link.parent] {
                // Si el dedo es fino y el píxel LiDAR leyó la pared del fondo, inferimos el
                // escorzo 3D desde la longitud anatómica del hueso y la distancia 2D en pantalla.
                let dxMeters = (Float(childPt.x - parentPt.x) / focal) * parentDepth
                let dyMeters = (Float(childPt.y - parentPt.y) / focal) * parentDepth
                let planarSq = dxMeters * dxMeters + dyMeters * dyMeters
                let nominalLen = baseMetricPalm * link.ratio
                let dz = sqrt(max(0.0, nominalLen * nominalLen - min(planarSq, nominalLen * nominalLen)))
                // Las falanges distales suelen arquearse ligeramente hacia la cámara al interactuar (-dz * 0.35).
                let inferred = parentDepth - dz * 0.35
                jointDepths[link.child] = clampNear(inferred, ref: anchorDepth, maxDelta: 0.14)
            } else {
                jointDepths[link.child] = parentDepth
            }
        }

        // Asegurar que cualquier articulación restante tenga profundidad válida.
        for (name, _) in screenJoints where jointDepths[name] == nil {
            jointDepths[name] = anchorDepth
        }

        // 3. Desproyectar las 21 articulaciones al espacio 3D de cámara y mundo.
        var cameraJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
        var worldJoints: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]

        for (name, pt) in screenJoints {
            let d = jointDepths[name] ?? anchorDepth
            let cam3D = pose.unprojectToCamera(screenPoint: pt, depth: d)
            cameraJoints[name] = cam3D
            worldJoints[name] = pose.cameraToWorld(cam3D)
        }

        return Reconstruction3D(palmDepthMeters: anchorDepth,
                                hasLiDAR: hasLiDAR,
                                jointDepths: jointDepths,
                                cameraJoints: cameraJoints,
                                worldJoints: worldJoints)
    }

    /// Lee un punto individual del mapa de profundidad del LiDAR (con bloqueo propio).
    static func depth(at point: CGPoint,
                      depthMap: CVPixelBuffer,
                      imageAspect: CGFloat,
                      viewport: CGSize,
                      orientation: UIInterfaceOrientation) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        return sampleLockedDepth(at: point,
                                 depthMap: depthMap,
                                 confidenceMap: nil,
                                 imageAspect: imageAspect,
                                 viewport: viewport,
                                 orientation: orientation,
                                 referenceDepth: nil)
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

        // 1) Coordenadas de pantalla → imagen normalizada [0, 1]
        let scale = max(viewport.width / imageAspect, viewport.height)
        let drawnWidth = imageAspect * scale
        let normalizedX = (point.x - (viewport.width - drawnWidth) / 2) / drawnWidth
        let normalizedY = 1 - (point.y - (viewport.height - scale) / 2) / scale
        guard normalizedX >= 0, normalizedX <= 1,
              normalizedY >= 0, normalizedY <= 1 else { return nil }

        // 2) Imagen orientada → coordenadas del buffer nativo del sensor
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

        // Ventana 3x3 alrededor de la articulación para evitar píxeles muertos o bordes.
        for dy in -1...1 {
            let y = min(max(centerY + dy, 0), height - 1)
            for dx in -1...1 {
                let x = min(max(centerX + dx, 0), width - 1)

                if let confBase, confWidth == width, confHeight == height {
                    let confPtr = confBase.advanced(by: y * confRowBytes + x)
                    let conf = confPtr.assumingMemoryBound(to: UInt8.self).pointee
                    if conf == 0 { continue } // descartar baja confianza si hay otras muestras
                }

                let ptr = base.advanced(by: y * rowBytes + x * 4)
                let meters = ptr.assumingMemoryBound(to: Float32.self).pointee
                guard meters.isFinite, meters > 0.10, meters < 2.20 else { continue }

                if let ref = referenceDepth {
                    // Rechazar píxeles del fondo que estén > 15 cm detrás de la palma.
                    guard meters >= ref - 0.18, meters <= ref + 0.15 else { continue }
                }
                samples.append(meters)
            }
        }

        // Si el filtro de confianza descartó todo, intentar una lectura directa del centro.
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
        // Tomamos el percentil frontal (primer tercio) para priorizar la superficie de la mano
        // frente al fondo de la habitación.
        return samples[max(0, samples.count / 3)]
    }
}
