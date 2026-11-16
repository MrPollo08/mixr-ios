import QuartzCore
import UIKit
import Vision
import simd

/// Capa de renderizado Overlay (`zPosition = 1000`) para la **Malla 3D Low-Poly de la Mano**
/// y los cursores espaciales, siempre visible por encima de los escenarios y ventanas.
///
/// Inspirada en el pipeline de referencia (@queryer Vision + LiDAR 3D Hand Mesh):
/// - Malla articulada de 21 puntos y 19 huesos con espesor cónico (tapered capsules)
///   escalado por la profundidad métrica real del sensor LiDAR.
/// - Cuerpo oscuro translúcido (`charcoal black`) con borde exterior blanco nítido
///   (Rim / Silhouette Outline) y sombreado cilíndrico 3D interno (Fresnel).
/// - Ordenamiento Z real por falange (auto-oclusión 3D cuando los dedos se cruzan o doblan).
/// - Gradiente alfa en la muñeca (`CAGradientLayer` en GPU) para fundir suavemente
///   la malla 3D de la mano con el brazo real del usuario.
final class HandOverlayView: UIView {

    /// Grupo de capas GPU por cada mano detectada (hasta 2 manos simultáneas).
    private final class HandMeshLayerGroup {
        let container = CALayer()
        let wristMask = CAGradientLayer()

        /// Pass 1: Contorno exterior blanco continuo (Silhouette Rim).
        let outerRimLayer = CAShapeLayer()
        /// Pass 2: Borde interno Fresnel gris suave.
        let fresnelLayer = CAShapeLayer()
        /// Pass 3: Relleno principal negro/carbón profundo.
        let coreBodyLayer = CAShapeLayer()
        /// Pass 4: Falanges en primer plano (ordenadas por Z LiDAR) + pliegues de auto-oclusión.
        let foregroundCreaseLayer = CAShapeLayer()
        let foregroundFillLayer = CAShapeLayer()
        /// Pass 5: Sombreado volumétrico 3D a lo largo de los huesos de la malla low-poly.
        let volumeShadingLayer = CAShapeLayer()

        init() {
            container.opacity = 0.90

            outerRimLayer.fillRule = .nonZero
            outerRimLayer.fillColor = UIColor(white: 0.97, alpha: 0.96).cgColor
            outerRimLayer.strokeColor = UIColor(white: 0.97, alpha: 0.96).cgColor
            outerRimLayer.lineWidth = 4.6
            outerRimLayer.lineJoin = .round
            outerRimLayer.lineCap = .round

            fresnelLayer.fillRule = .nonZero
            fresnelLayer.fillColor = UIColor(red: 0.22, green: 0.23, blue: 0.26, alpha: 1.0).cgColor
            fresnelLayer.strokeColor = UIColor(red: 0.22, green: 0.23, blue: 0.26, alpha: 1.0).cgColor
            fresnelLayer.lineWidth = 1.6
            fresnelLayer.lineJoin = .round
            fresnelLayer.lineCap = .round

            coreBodyLayer.fillRule = .nonZero
            coreBodyLayer.fillColor = UIColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1.0).cgColor
            coreBodyLayer.strokeColor = nil

            foregroundCreaseLayer.fillRule = .nonZero
            foregroundCreaseLayer.fillColor = UIColor(white: 0.92, alpha: 0.82).cgColor
            foregroundCreaseLayer.strokeColor = UIColor(white: 0.92, alpha: 0.82).cgColor
            foregroundCreaseLayer.lineWidth = 2.6
            foregroundCreaseLayer.lineJoin = .round
            foregroundCreaseLayer.lineCap = .round

            foregroundFillLayer.fillRule = .nonZero
            foregroundFillLayer.fillColor = UIColor(red: 0.055, green: 0.06, blue: 0.078, alpha: 1.0).cgColor
            foregroundFillLayer.strokeColor = nil

            volumeShadingLayer.fillColor = nil
            volumeShadingLayer.strokeColor = UIColor(red: 0.30, green: 0.33, blue: 0.39, alpha: 0.28).cgColor
            volumeShadingLayer.lineCap = .round
            volumeShadingLayer.lineJoin = .round

            // Máscara axial en GPU para desvanecer suavemente la muñeca hacia el brazo real.
            wristMask.type = .axial
            wristMask.colors = [
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor(white: 1.0, alpha: 0.42).cgColor,
                UIColor.clear.cgColor
            ]
            wristMask.locations = [0.0, 0.22, 0.68, 1.0]

            for sub in [
                outerRimLayer,
                fresnelLayer,
                coreBodyLayer,
                foregroundCreaseLayer,
                foregroundFillLayer,
                volumeShadingLayer
            ] {
                container.addSublayer(sub)
            }
            container.mask = wristMask
        }

        func updateBounds(_ bounds: CGRect) {
            container.frame = bounds
            wristMask.frame = bounds
            for sub in [
                outerRimLayer,
                fresnelLayer,
                coreBodyLayer,
                foregroundCreaseLayer,
                foregroundFillLayer,
                volumeShadingLayer
            ] {
                sub.frame = bounds
            }
        }

        func clear() {
            outerRimLayer.path = nil
            fresnelLayer.path = nil
            coreBodyLayer.path = nil
            foregroundCreaseLayer.path = nil
            foregroundFillLayer.path = nil
            volumeShadingLayer.path = nil
        }
    }

    private let handGroups = [HandMeshLayerGroup(), HandMeshLayerGroup()]
    private let palmButtonLayer = CAShapeLayer()
    private let pointerLayer = CAShapeLayer()
    private let grabDotLayer = CAShapeLayer()

    /// Largo del rayo espacial (pt).
    static let rayLength: CGFloat = 190
    /// Permite mostrar la malla 3D low-poly siempre activa encima de los escenarios.
    var showsSkeleton = true
    private var pointerVisible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.zPosition = 1000

        for group in handGroups {
            layer.addSublayer(group.container)
        }

        palmButtonLayer.fillColor = UIColor(white: 0.12, alpha: 0.72).cgColor
        palmButtonLayer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        palmButtonLayer.lineWidth = 2

        pointerLayer.fillColor = UIColor.white.cgColor
        pointerLayer.strokeColor = UIColor.white.withAlphaComponent(0.92).cgColor
        pointerLayer.lineWidth = 2

        grabDotLayer.fillColor = UIColor.white.withAlphaComponent(0.95).cgColor
        grabDotLayer.strokeColor = UIColor(red: 0.42, green: 0.86, blue: 1.0, alpha: 0.95).cgColor
        grabDotLayer.lineWidth = 3

        for shape in [palmButtonLayer, pointerLayer, grabDotLayer] {
            layer.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for group in handGroups {
            group.updateBounds(bounds)
        }
        for shape in [palmButtonLayer, pointerLayer, grabDotLayer] {
            shape.frame = bounds
        }
        CATransaction.commit()
    }

    /// Activa o desactiva el rayo puntero cuando la mano apunta a una ventana o menú.
    func setPointer(_ point: CGPoint?) {
        pointerVisible = (point != nil)
    }

    // MARK: - Renderizado de la Malla 3D Low-Poly + Overlay UI

    func render(poses: [HandPose]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (index, group) in handGroups.enumerated() {
            if index < poses.count {
                renderHandMesh(pose: poses[index], into: group)
            } else {
                group.clear()
            }
        }

        // Rayo espacial desde el dedo índice con cursor en la punta.
        if pointerVisible, let pose = poses.first,
           let tip = pose.joints[.indexTip] {
            let base = pose.joints[.indexMCP] ?? pose.joints[.wrist] ?? tip
            let dx = tip.x - base.x
            let dy = tip.y - base.y
            let length = max(hypot(dx, dy), 1)
            let end = CGPoint(x: tip.x + dx / length * Self.rayLength,
                              y: tip.y + dy / length * Self.rayLength)

            let ray = UIBezierPath()
            ray.move(to: tip)
            ray.addLine(to: end)
            ray.append(UIBezierPath(ovalIn: CGRect(x: end.x - 5.5, y: end.y - 5.5,
                                                   width: 11, height: 11)))
            pointerLayer.path = ray.cgPath
        } else {
            pointerLayer.path = nil
        }

        // Indicador de pinza activa sobre borde de ventana.
        if let pinchingHand = poses.first(where: { $0.pinch >= 0.55 }) {
            let radius: CGFloat = 6.5
            let center = pinchingHand.pinchPoint
            grabDotLayer.path = UIBezierPath(ovalIn: CGRect(x: center.x - radius,
                                                            y: center.y - radius,
                                                            width: radius * 2,
                                                            height: radius * 2)).cgPath
        } else {
            grabDotLayer.path = nil
        }

        palmButtonLayer.path = nil
        CATransaction.commit()
    }

    // MARK: - Construcción geométrica 3D → Malla Low-Poly con sombreado y fade en muñeca

    private func renderHandMesh(pose: HandPose, into group: HandMeshLayerGroup) {
        let joints = pose.joints
        guard let wrist = joints[.wrist],
              let middleMCP = joints[.middleMCP] else {
            group.clear()
            return
        }

        let rawPalmScale = hypot(wrist.x - middleMCP.x, wrist.y - middleMCP.y)
        let palmScale = min(max(rawPalmScale, 18), 280)

        // Dirección anatómica del antebrazo (desde los nudillos hacia la muñeca).
        let palmAnchor = averagePoint([
            joints[.indexMCP],
            joints[.middleMCP],
            joints[.ringMCP],
            joints[.littleMCP]
        ]) ?? middleMCP

        var forearmDir = CGPoint(x: wrist.x - palmAnchor.x, y: wrist.y - palmAnchor.y)
        let dirLen = max(hypot(forearmDir.x, forearmDir.y), 0.001)
        forearmDir.x /= dirLen
        forearmDir.y /= dirLen

        let forearmLen = palmScale * 0.82
        let forearmEnd = CGPoint(x: wrist.x + forearmDir.x * forearmLen,
                                 y: wrist.y + forearmDir.y * forearmLen)

        // Actualizar la máscara de gradiente en la muñeca (de opaco en la palma a transparente en el antebrazo).
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let maskStart = CGPoint(x: wrist.x - forearmDir.x * (palmScale * 0.24),
                                y: wrist.y - forearmDir.y * (palmScale * 0.24))
        let maskEnd = CGPoint(x: wrist.x + forearmDir.x * (forearmLen * 0.86),
                              y: wrist.y + forearmDir.y * (forearmLen * 0.86))
        group.wristMask.startPoint = CGPoint(x: maskStart.x / w, y: maskStart.y / h)
        group.wristMask.endPoint = CGPoint(x: maskEnd.x / w, y: maskEnd.y / h)

        let fullSilhouette = CGMutablePath()
        let volumeShading = CGMutablePath()

        // 1. Extensión de muñeca / antebrazo (se desvanece antes del extremo final gracias al wristMask).
        let wristRadius = palmScale * 0.31
        let forearmRadius = palmScale * 0.28
        Self.addTaperedCapsule(to: fullSilhouette,
                               from: wrist,
                               to: forearmEnd,
                               rA: wristRadius,
                               rB: forearmRadius)

        // 2. Malla de la palma + membranas interdigitales (webbing anatómico).
        addPalmAndWebbing(joints: joints, palmScale: palmScale, to: fullSilhouette)

        // 3. Los 19 huesos articulados cónicos (Tapered Phalanx Capsules).
        let sortedBones = pose.bones3D.sorted { $0.depthMeters > $1.depthMeters } // de más lejos a más cerca
        for bone in sortedBones {
            let r0 = palmScale * bone.definition.radiusStartRatio
            let r1 = palmScale * bone.definition.radiusEndRatio
            Self.addTaperedCapsule(to: fullSilhouette,
                                   from: bone.start2D,
                                   to: bone.end2D,
                                   rA: r0,
                                   rB: r1)

            // Cresta de iluminación 3D central en las falanges visibles.
            if bone.definition.segmentIndex >= 1 {
                volumeShading.move(to: bone.start2D)
                volumeShading.addLine(to: bone.end2D)
            }
        }

        // 4. Auto-oclusión 3D (pliegue blanco sutil para dedos que pasan por delante de la palma
        //    o de otros dedos según la profundidad real LiDAR).
        let foregroundPath = CGMutablePath()
        let palmDepth = pose.depthMeters
        for bone in sortedBones where bone.definition.segmentIndex >= 1 {
            // Si la falange está más cerca de la cámara que el plano medio de la palma (o es el pulgar en escorzo).
            if bone.depthMeters < palmDepth - 0.008 || bone.definition.fingerIndex == 0 {
                let r0 = palmScale * bone.definition.radiusStartRatio * 0.96
                let r1 = palmScale * bone.definition.radiusEndRatio * 0.96
                Self.addTaperedCapsule(to: foregroundPath,
                                       from: bone.start2D,
                                       to: bone.end2D,
                                       rA: r0,
                                       rB: r1)
            }
        }

        // Ajustar grosores proporcionalmente al tamaño aparente/métrico de la mano.
        let rimScale = min(max(palmScale / 85.0, 0.72), 1.45)
        group.outerRimLayer.lineWidth = 4.6 * rimScale
        group.fresnelLayer.lineWidth = 1.6 * rimScale
        group.foregroundCreaseLayer.lineWidth = 2.4 * rimScale
        group.volumeShadingLayer.lineWidth = max(2.2, palmScale * 0.085)

        group.outerRimLayer.path = fullSilhouette
        group.fresnelLayer.path = fullSilhouette
        group.coreBodyLayer.path = fullSilhouette
        group.foregroundCreaseLayer.path = foregroundPath
        group.foregroundFillLayer.path = foregroundPath
        group.volumeShadingLayer.path = volumeShading
    }

    /// Construye el volumen anatómico de la palma, eminencia tenar/hipotenar y membranas interdigitales.
    private func addPalmAndWebbing(joints: [VNHumanHandPoseObservation.JointName: CGPoint],
                                   palmScale: CGFloat,
                                   to path: CGMutablePath) {
        guard let wrist = joints[.wrist] else { return }

        // Puntos de membrana interdigital (~26% desde el nudillo MCP hacia la falange PIP).
        let indexWeb = lerpPoint(joints[.indexMCP], joints[.indexPIP], t: 0.26)
        let middleWeb = lerpPoint(joints[.middleMCP], joints[.middlePIP], t: 0.26)
        let ringWeb = lerpPoint(joints[.ringMCP], joints[.ringPIP], t: 0.26)
        let littleWeb = lerpPoint(joints[.littleMCP], joints[.littlePIP], t: 0.24)
        let thumbWeb = lerpPoint(joints[.thumbMP], joints[.thumbIP], t: 0.28)

        // Cápsulas transversales en el arco metacarpiano y la base de la palma para suavizar uniones.
        let bridgePairs: [(CGPoint?, CGPoint?, CGFloat, CGFloat)] = [
            (joints[.indexMCP], joints[.middleMCP], 0.19, 0.19),
            (joints[.middleMCP], joints[.ringMCP], 0.19, 0.18),
            (joints[.ringMCP], joints[.littleMCP], 0.18, 0.16),
            (indexWeb, middleWeb, 0.145, 0.145),
            (middleWeb, ringWeb, 0.145, 0.140),
            (ringWeb, littleWeb, 0.135, 0.125),
            (joints[.thumbCMC], joints[.indexMCP], 0.22, 0.19),
            (joints[.thumbMP], indexWeb, 0.16, 0.14),
            (thumbWeb, joints[.indexMCP], 0.13, 0.15),
            (wrist, joints[.thumbCMC], 0.28, 0.23),
            (wrist, joints[.littleMCP], 0.27, 0.18)
        ]

        for (a, b, rA, rB) in bridgePairs {
            if let p0 = a, let p1 = b {
                Self.addTaperedCapsule(to: path,
                                       from: p0,
                                       to: p1,
                                       rA: palmScale * rA,
                                       rB: palmScale * rB)
            }
        }

        // Polígono central relleno de la palma (con winding positivo garantizado).
        let hullCandidates: [CGPoint?] = [
            wrist,
            joints[.thumbCMC],
            joints[.thumbMP],
            indexWeb ?? joints[.indexMCP],
            middleWeb ?? joints[.middleMCP],
            ringWeb ?? joints[.ringMCP],
            littleWeb ?? joints[.littleMCP]
        ]
        let hull = hullCandidates.compactMap { $0 }
        if hull.count >= 4 {
            Self.addPositiveWindingPolygon(points: hull, to: path)
        }
    }

    // MARK: - Primitivas geométricas con Winding Positivo (sin huecos bajo fillRule = .nonZero)

    private static func addTaperedCapsule(to path: CGMutablePath,
                                          from a: CGPoint,
                                          to b: CGPoint,
                                          rA: CGFloat,
                                          rB: CGFloat) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dist = hypot(dx, dy)
        let safeRA = max(rA, 1.0)
        let safeRB = max(rB, 1.0)

        if dist < 0.5 {
            let r = max(safeRA, safeRB)
            path.move(to: CGPoint(x: a.x + r, y: a.y))
            path.addArc(center: a, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            path.closeSubpath()
            return
        }

        let angle = atan2(dy, dx)
        let startA = angle - .pi * 0.5
        let endA = angle + .pi * 0.5

        let p0 = CGPoint(x: a.x + cos(startA) * safeRA, y: a.y + sin(startA) * safeRA)
        let p1 = CGPoint(x: b.x + cos(startA) * safeRB, y: b.y + sin(startA) * safeRB)
        let p2 = CGPoint(x: a.x + cos(endA) * safeRA, y: a.y + sin(endA) * safeRA)

        path.move(to: p0)
        path.addLine(to: p1)
        path.addArc(center: b, radius: safeRB, startAngle: startA, endAngle: endA, clockwise: false)
        path.addLine(to: p2)
        path.addArc(center: a, radius: safeRA, startAngle: endA, endAngle: startA + .pi * 2, clockwise: false)
        path.closeSubpath()
    }

    private static func addPositiveWindingPolygon(points: [CGPoint], to path: CGMutablePath) {
        guard points.count >= 3 else { return }
        var area: CGFloat = 0
        for i in 0..<points.count {
            let p1 = points[i]
            let p2 = points[(i + 1) % points.count]
            area += (p1.x * p2.y - p2.x * p1.y)
        }
        let ordered = area >= 0 ? points : Array(points.reversed())
        path.move(to: ordered[0])
        for i in 1..<ordered.count {
            path.addLine(to: ordered[i])
        }
        path.closeSubpath()
    }

    private func lerpPoint(_ a: CGPoint?, _ b: CGPoint?, t: CGFloat) -> CGPoint? {
        guard let a else { return b }
        guard let b else { return a }
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func averagePoint(_ points: [CGPoint?]) -> CGPoint? {
        let valid = points.compactMap { $0 }
        guard !valid.isEmpty else { return nil }
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        for pt in valid {
            sx += pt.x
            sy += pt.y
        }
        return CGPoint(x: sx / CGFloat(valid.count), y: sy / CGFloat(valid.count))
    }
}
