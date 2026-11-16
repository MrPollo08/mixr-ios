import QuartzCore
import UIKit
import Vision
import simd

/// Capa de renderizado Overlay (`zPosition = 1000`): **malla de mano + antebrazo con volumen**.
///
/// La silueta se compone como **unión de formas** (19 huesos, palma y antebrazo) y se
/// pinta en varias pasadas para que se lea como un cuerpo 3D y no como un dibujo de líneas:
///
/// 1. `outlineLayer` — el path con un trazo **grueso y claro** + halo suave.
/// 2. `baseFillLayer` — el mismo path **relleno oscuro opaco**: tapa la mitad interior
///    del trazo, así queda **una sola línea continua alrededor de la silueta**.
/// 3. `shadeLayer` — degradado axial (luz arriba-izquierda → sombra abajo-derecha)
///    recortado a la silueta: da forma y curvatura.
/// 4. `highlightLayer` — degradado radial suave sobre la palma: volumen.
///
/// Los degradados son GPU (`CAGradientLayer` con máscara de path), así que no cuesta FPS.
final class HandOverlayView: UIView {

    private final class HandMeshGroup {
        let container = CALayer()
        let wristMask = CAGradientLayer()

        let shadowLayer = CAShapeLayer()
        let outlineLayer = CAShapeLayer()
        let baseFillLayer = CAShapeLayer()

        let shadeLayer = CAGradientLayer()
        let shadeMask = CAShapeLayer()

        let highlightLayer = CAGradientLayer()
        let highlightMask = CAShapeLayer()

        init() {
            container.opacity = 0.90

            // Trazo grueso: la mitad interior la tapa el relleno opaco.
            outlineLayer.fillColor = UIColor.clear.cgColor
            outlineLayer.strokeColor = UIColor(white: 0.965, alpha: 1.0).cgColor
            outlineLayer.lineWidth = 4.0
            outlineLayer.lineJoin = .round
            outlineLayer.lineCap = .round
            outlineLayer.fillRule = .nonZero
            // Halo suave alrededor del contorno.
            outlineLayer.shadowColor = UIColor(white: 1.0, alpha: 1.0).cgColor
            outlineLayer.shadowOpacity = 0.35
            outlineLayer.shadowRadius = 3.0
            outlineLayer.shadowOffset = .zero

            baseFillLayer.fillColor = UIColor(red: 0.115, green: 0.120, blue: 0.130, alpha: 1.0).cgColor
            baseFillLayer.strokeColor = nil
            baseFillLayer.fillRule = .nonZero

            shadeLayer.type = .axial
            shadeLayer.colors = [
                UIColor(white: 1.0, alpha: 0.16).cgColor,
                UIColor(white: 0.55, alpha: 0.02).cgColor,
                UIColor(white: 0.0, alpha: 0.34).cgColor
            ]
            shadeLayer.locations = [0.0, 0.42, 1.0]
            shadeLayer.startPoint = CGPoint(x: 0.28, y: 0.02)
            shadeLayer.endPoint = CGPoint(x: 0.78, y: 1.0)
            shadeMask.fillColor = UIColor.white.cgColor
            shadeMask.fillRule = .nonZero
            shadeLayer.mask = shadeMask

            highlightLayer.type = .radial
            highlightLayer.colors = [
                UIColor(white: 1.0, alpha: 0.14).cgColor,
                UIColor(white: 1.0, alpha: 0.04).cgColor,
                UIColor(white: 1.0, alpha: 0.0).cgColor
            ]
            highlightLayer.locations = [0.0, 0.45, 1.0]
            highlightLayer.startPoint = CGPoint(x: 0.45, y: 0.30)
            highlightLayer.endPoint = CGPoint(x: 1.15, y: 1.15)
            highlightMask.fillColor = UIColor.white.cgColor
            highlightMask.fillRule = .nonZero
            highlightLayer.mask = highlightMask

            shadowLayer.fillColor = UIColor.black.withAlphaComponent(0.30).cgColor
            shadowLayer.strokeColor = nil
            shadowLayer.fillRule = .nonZero

            container.addSublayer(shadowLayer)
            container.addSublayer(outlineLayer)
            container.addSublayer(baseFillLayer)
            container.addSublayer(shadeLayer)
            container.addSublayer(highlightLayer)

            // Desvanecido del antebrazo hacia el brazo real (GPU).
            wristMask.type = .axial
            wristMask.colors = [
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor(white: 1.0, alpha: 0.42).cgColor,
                UIColor.clear.cgColor
            ]
            wristMask.locations = [0.0, 0.34, 0.72, 1.0]
            container.mask = wristMask
        }

        func applyBounds(_ bounds: CGRect) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = bounds
            wristMask.frame = bounds
            shadowLayer.frame = bounds
            outlineLayer.frame = bounds
            baseFillLayer.frame = bounds
            shadeLayer.frame = bounds
            shadeMask.frame = bounds
            highlightLayer.frame = bounds
            highlightMask.frame = bounds
            CATransaction.commit()
        }

        func clear() {
            shadowLayer.path = nil
            outlineLayer.path = nil
            baseFillLayer.path = nil
            shadeMask.path = nil
            highlightMask.path = nil
        }
    }

    private let groups = [HandMeshGroup(), HandMeshGroup()]

    var showsSkeleton = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.zPosition = 1000
        for group in groups { layer.addSublayer(group.container) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for group in groups { group.applyBounds(bounds) }
    }

    /// Se conserva por compatibilidad: el cursor ya no se dibuja.
    func setPointer(_ point: CGPoint?) {}

    func render(poses: [HandPose]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (index, group) in groups.enumerated() {
            if index < poses.count, showsSkeleton {
                renderSilhouette(pose: poses[index], group: group)
            } else {
                group.clear()
            }
        }

        CATransaction.commit()
    }

    // MARK: - Silueta

    /// Construye la silueta (mano + antebrazo) como unión de cápsulas.
    /// Es `static` para que la use también el pase de segmentación como máscara de respaldo.
    static func silhouettePath(for pose: HandPose) -> CGPath? {
        let joints = pose.joints
        guard let wrist = joints[.wrist], let middleMCP = joints[.middleMCP] else { return nil }

        let scale = min(max(pose.palmScale, 14), 340)
        let path = CGMutablePath()

        var armDir = pose.forearm.direction2D
        if !armDir.x.isFinite || !armDir.y.isFinite || (abs(armDir.x) + abs(armDir.y)) < 0.01 {
            armDir = normalizePoint(CGPoint(x: wrist.x - middleMCP.x, y: wrist.y - middleMCP.y),
                                    fallback: CGPoint(x: 0, y: 1))
        }
        let armLength = max(hypot(pose.forearm.elbow2D.x - wrist.x,
                                  pose.forearm.elbow2D.y - wrist.y), scale * 1.2)
        let elbow = CGPoint(x: wrist.x + armDir.x * armLength,
                            y: wrist.y + armDir.y * armLength)

        addCapsule(to: path, from: wrist, to: elbow,
                   rA: scale * 0.330, rB: scale * 0.395)

        let hullNames: [VNHumanHandPoseObservation.JointName] = [
            .wrist, .thumbCMC, .indexMCP, .middleMCP, .ringMCP, .littleMCP
        ]
        let hull = hullNames.compactMap { joints[$0] }
        if hull.count >= 3 { addPolygon(to: path, points: hull) }

        let palmBridges: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, CGFloat)] = [
            (.indexMCP, .middleMCP, 0.170),
            (.middleMCP, .ringMCP, 0.170),
            (.ringMCP, .littleMCP, 0.158),
            (.thumbCMC, .indexMCP, 0.195),
            (.wrist, .thumbCMC, 0.225),
            (.wrist, .littleMCP, 0.205),
            (.wrist, .middleMCP, 0.200),
            (.wrist, .indexMCP, 0.195),
            (.wrist, .ringMCP, 0.195)
        ]
        for (fromName, toName, radius) in palmBridges {
            guard let a = joints[fromName], let b = joints[toName] else { continue }
            addCapsule(to: path, from: a, to: b,
                       rA: scale * radius, rB: scale * radius * 0.94)
        }

        let orderedBones = pose.bones3D.sorted { $0.depthMeters > $1.depthMeters }
        for bone in orderedBones {
            addCapsule(to: path,
                       from: bone.start2D,
                       to: bone.end2D,
                       rA: scale * bone.definition.radiusStartRatio,
                       rB: scale * bone.definition.radiusEndRatio)
        }

        return path.isEmpty ? nil : path
    }

    private func renderSilhouette(pose: HandPose, group: HandMeshGroup) {
        guard let path = Self.silhouettePath(for: pose) else {
            group.clear()
            return
        }

        let joints = pose.joints
        guard let wrist = joints[.wrist], let middleMCP = joints[.middleMCP] else {
            group.clear()
            return
        }

        let scale = min(max(pose.palmScale, 14), 340)

        var armDir = pose.forearm.direction2D
        if !armDir.x.isFinite || !armDir.y.isFinite || (abs(armDir.x) + abs(armDir.y)) < 0.01 {
            armDir = normalizePoint(CGPoint(x: wrist.x - middleMCP.x, y: wrist.y - middleMCP.y),
                                   fallback: CGPoint(x: 0, y: 1))
        }
        let armLength = max(hypot(pose.forearm.elbow2D.x - wrist.x,
                                  pose.forearm.elbow2D.y - wrist.y), scale * 1.2)

        // --- Desvanecido del antebrazo ---
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let maskFrom = CGPoint(x: wrist.x - armDir.x * (scale * 0.30),
                               y: wrist.y - armDir.y * (scale * 0.30))
        let maskTo = CGPoint(x: wrist.x + armDir.x * (armLength * 0.95),
                             y: wrist.y + armDir.y * (armLength * 0.95))
        group.wristMask.startPoint = CGPoint(x: maskFrom.x / w, y: maskFrom.y / h)
        group.wristMask.endPoint = CGPoint(x: maskTo.x / w, y: maskTo.y / h)

        // Grosor del contorno según profundidad real (más cerca = algo más marcado).
        let depthFactor = CGFloat(min(max(0.62 / max(CGFloat(pose.depthMeters), 0.12), 0.80), 1.60))
        group.outlineLayer.lineWidth = 3.6 * depthFactor

        // Sombra de contacto desplazada (apoya la mano sobre el escenario).
        let shadowPath = CGMutablePath()
        shadowPath.addPath(path, transform: CGAffineTransform(translationX: 2.5, y: 5.0))

        group.shadowLayer.path = shadowPath
        group.outlineLayer.path = path
        group.baseFillLayer.path = path
        group.shadeMask.path = path
        group.highlightMask.path = path

        // El degradado de luz arranca en la punta de los dedos y baja hacia la muñeca:
        // así el volumen sigue la forma de la mano en cualquier orientación.
        let top = joints[.middleTip] ?? middleMCP
        group.shadeLayer.startPoint = CGPoint(x: top.x / w, y: top.y / h)
        group.shadeLayer.endPoint = CGPoint(x: wrist.x / w, y: wrist.y / h)
        group.highlightLayer.startPoint = CGPoint(x: (pose.palmCenter.x / w),
                                                  y: (pose.palmCenter.y / h))
        group.highlightLayer.endPoint = CGPoint(x: min((pose.palmCenter.x / w) + 0.55, 1.4),
                                                y: min((pose.palmCenter.y / h) + 0.55, 1.4))
    }

    // MARK: - Primitivas

    static func normalizePoint(_ p: CGPoint, fallback: CGPoint) -> CGPoint {
        let len = hypot(p.x, p.y)
        guard len > 1e-4 else { return fallback }
        return CGPoint(x: p.x / len, y: p.y / len)
    }

    /// Cápsula cónica. Todos los subpaths se fuerzan al mismo sentido de giro para que
    /// `fillRule = .nonZero` no abra huecos en las uniones.
    static func addCapsule(to path: CGMutablePath,
                            from a: CGPoint,
                            to b: CGPoint,
                            rA: CGFloat,
                            rB: CGFloat,
                            capSamples: Int = 8) {
        let safeRA = max(rA, 0.8)
        let safeRB = max(rB, 0.8)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let distance = hypot(dx, dy)

        if distance < 0.6 {
            var points: [CGPoint] = []
            let radius = max(safeRA, safeRB)
            for i in 0..<16 {
                let theta = CGFloat(i) / 16 * 2 * .pi
                points.append(CGPoint(x: a.x + cos(theta) * radius,
                                      y: a.y + sin(theta) * radius))
            }
            addPolygon(to: path, points: points)
            return
        }

        let angle = atan2(dy, dx)
        var points: [CGPoint] = []
        points.reserveCapacity(capSamples * 2 + 4)

        // Lado "izquierdo": base → punta.
        let left = angle + .pi / 2
        points.append(CGPoint(x: a.x + cos(left) * safeRA, y: a.y + sin(left) * safeRA))
        points.append(CGPoint(x: b.x + cos(left) * safeRB, y: b.y + sin(left) * safeRB))

        // Extremo b: semicírculo por delante.
        for i in 1...capSamples {
            let t = CGFloat(i) / CGFloat(capSamples)
            let theta = angle + .pi / 2 - .pi * t
            points.append(CGPoint(x: b.x + cos(theta) * safeRB, y: b.y + sin(theta) * safeRB))
        }

        // Lado "derecho": punta → base.
        let right = angle - .pi / 2
        points.append(CGPoint(x: b.x + cos(right) * safeRB, y: b.y + sin(right) * safeRB))
        points.append(CGPoint(x: a.x + cos(right) * safeRA, y: a.y + sin(right) * safeRA))

        // Extremo a: semicírculo por detrás.
        for i in 1...capSamples {
            let t = CGFloat(i) / CGFloat(capSamples)
            let theta = angle - .pi / 2 - .pi * t
            points.append(CGPoint(x: a.x + cos(theta) * safeRA, y: a.y + sin(theta) * safeRA))
        }

        addPolygon(to: path, points: points)
    }

    /// Polígono cerrado con área positiva garantizada (sentido de giro consistente).
    static func addPolygon(to path: CGMutablePath, points: [CGPoint]) {
        guard points.count >= 3 else { return }

        var area: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            area += (a.x * b.y - b.x * a.y)
        }
        let ordered = area >= 0 ? points : Array(points.reversed())

        path.move(to: ordered[0])
        for i in 1..<ordered.count { path.addLine(to: ordered[i]) }
        path.closeSubpath()
    }
}
