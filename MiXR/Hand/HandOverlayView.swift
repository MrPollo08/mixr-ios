import QuartzCore
import UIKit
import Vision
import simd

/// Capa de renderizado Overlay (`zPosition = 1000`): **malla de mano + antebrazo**.
///
/// El dibujo es un **único contorno cerrado** (perímetro real de la silueta), tal como
/// en la referencia: relleno translúcido oscuro, línea fina clara por fuera, muescas
/// en V entre los dedos y continuidad hacia el antebrazo que se desvanece en el brazo.
///
/// Al ser un solo polígono no hay líneas internas, ni parches de distinta opacidad,
/// ni costuras entre falanges: el relleno es uniforme y el borde, continuo.
final class HandOverlayView: UIView {

    private final class HandMeshGroup {
        let container = CALayer()
        let wristMask = CAGradientLayer()

        /// Relleno translúcido de toda la silueta.
        let fillLayer = CAShapeLayer()
        /// Línea fina exterior (contorno).
        let outlineLayer = CAShapeLayer()
        /// Sombra suave: da profundidad (la mano "flota" sobre el escenario).
        let shadowLayer = CAShapeLayer()

        init() {
            container.opacity = 0.94

            shadowLayer.fillColor = UIColor.black.withAlphaComponent(0.30).cgColor
            shadowLayer.strokeColor = nil

            fillLayer.fillColor = UIColor(white: 0.115, alpha: 0.58).cgColor
            fillLayer.strokeColor = nil
            fillLayer.fillRule = .nonZero

            outlineLayer.fillColor = UIColor.clear.cgColor
            outlineLayer.strokeColor = UIColor(white: 0.93, alpha: 0.92).cgColor
            outlineLayer.lineWidth = 1.7
            outlineLayer.lineJoin = .round
            outlineLayer.lineCap = .round
            outlineLayer.fillRule = .nonZero

            container.addSublayer(shadowLayer)
            container.addSublayer(fillLayer)
            container.addSublayer(outlineLayer)

            // Desvanecido axial sobre el antebrazo (GPU).
            wristMask.type = .axial
            wristMask.colors = [
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor(white: 1.0, alpha: 0.45).cgColor,
                UIColor.clear.cgColor
            ]
            wristMask.locations = [0.0, 0.30, 0.70, 1.0]
            container.mask = wristMask
        }

        func applyBounds(_ bounds: CGRect) {
            container.frame = bounds
            wristMask.frame = bounds
            shadowLayer.frame = bounds
            fillLayer.frame = bounds
            outlineLayer.frame = bounds
        }

        func clear() {
            shadowLayer.path = nil
            fillLayer.path = nil
            outlineLayer.path = nil
        }
    }

    private let groups = [HandMeshGroup(), HandMeshGroup()]
    private let pointerLayer = CAShapeLayer()
    private let touchDotLayer = CAShapeLayer()

    static let rayLength: CGFloat = 190
    var showsSkeleton = true
    private var pointerVisible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.zPosition = 1000

        for group in groups { layer.addSublayer(group.container) }

        pointerLayer.fillColor = UIColor.white.cgColor
        pointerLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        pointerLayer.lineWidth = 2

        touchDotLayer.fillColor = UIColor.clear.cgColor
        touchDotLayer.strokeColor = UIColor(white: 0.95, alpha: 0.85).cgColor
        touchDotLayer.lineWidth = 2

        layer.addSublayer(touchDotLayer)
        layer.addSublayer(pointerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for group in groups { group.applyBounds(bounds) }
        touchDotLayer.frame = bounds
        pointerLayer.frame = bounds
        CATransaction.commit()
    }

    func setPointer(_ point: CGPoint?) {
        pointerVisible = (point != nil)
    }

    // MARK: - Render

    func render(poses: [HandPose]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (index, group) in groups.enumerated() {
            if index < poses.count {
                renderSilhouette(pose: poses[index], group: group)
            } else {
                group.clear()
            }
        }

        if pointerVisible, let pose = poses.first, let tip = pose.joints[.indexTip] {
            let base = pose.joints[.indexMCP] ?? pose.joints[.wrist] ?? tip
            let dx = tip.x - base.x
            let dy = tip.y - base.y
            let len = max(hypot(dx, dy), 1)
            let end = CGPoint(x: tip.x + dx / len * Self.rayLength, y: tip.y + dy / len * Self.rayLength)
            let ray = UIBezierPath()
            ray.move(to: tip)
            ray.addLine(to: end)
            ray.append(UIBezierPath(ovalIn: CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10)))
            pointerLayer.path = ray.cgPath
        } else {
            pointerLayer.path = nil
        }

        // Aro de contacto para Direct Touch (yema tocando una superficie).
        if let pose = poses.first,
           let tip = pose.joints[.indexTip],
           let target = pose.joints[.indexDIP] {
            let dx = tip.x - target.x
            let dy = tip.y - target.y
            let len = max(hypot(dx, dy), 1)
            let end = CGPoint(x: tip.x + dx / len * 26, y: tip.y + dy / len * 26)
            touchDotLayer.path = UIBezierPath(ovalIn: CGRect(x: end.x - 9, y: end.y - 9,
                                                             width: 18, height: 18)).cgPath
        } else {
            touchDotLayer.path = nil
        }

        CATransaction.commit()
    }

    // MARK: - Silueta continua (mano + antebrazo)

    private func renderSilhouette(pose: HandPose, group: HandMeshGroup) {
        let joints = pose.joints
        guard let wrist = joints[.wrist],
              let middleMCP = joints[.middleMCP] else {
            group.clear()
            return
        }

        let scale = min(max(pose.palmScale, 16), 320)

        // Eje "hacia el pulgar" (radial) en pantalla: sirve para separar el lado
        // pulgar y el lado meñique sin importar cómo esté rotada la mano.
        var radial = CGPoint(x: 1, y: 0)
        if let index = joints[.indexMCP], let little = joints[.littleMCP] {
            let dx = index.x - little.x
            let dy = index.y - little.y
            let len = hypot(dx, dy)
            if len > 0.5 {
                radial = CGPoint(x: dx / len, y: dy / len)
            }
        } else {
            let palmDir = CGPoint(x: middleMCP.x - wrist.x, y: middleMCP.y - wrist.y)
            let len = max(hypot(palmDir.x, palmDir.y), 0.001)
            radial = CGPoint(x: -palmDir.y / len, y: palmDir.x / len)
        }
        let ulnar = CGPoint(x: -radial.x, y: -radial.y)

        // Dirección del antebrazo: muñeca → codo (Arm Tracking).
        var armDir = pose.forearm.direction2D
        let armLen = max(hypot(pose.forearm.elbow2D.x - wrist.x,
                               pose.forearm.elbow2D.y - wrist.y), scale * 1.1)

        // Si el codo quedó degenerado, usar la dirección anatómica nudillos → muñeca.
        if !armDir.x.isFinite || !armDir.y.isFinite || (armDir.x == 0 && armDir.y == 0) {
            let dx = wrist.x - middleMCP.x
            let dy = wrist.y - middleMCP.y
            let len = max(hypot(dx, dy), 0.001)
            armDir = CGPoint(x: dx / len, y: dy / len)
        }

        var contour: [CGPoint] = []

        // ---- 1. Borde cubital de la palma: muñeca → meñique ----
        let wristRadius = scale * 0.30
        let ulnarStart = offset(wrist, ulnar, wristRadius)
        contour.append(ulnarStart)

        if let little = joints[.littleMCP] {
            let midPalm = CGPoint(x: (wrist.x + little.x) * 0.5, y: (wrist.y + little.y) * 0.5)
            contour.append(offset(midPalm, ulnar, scale * 0.27))
            contour.append(offset(little, ulnar, scale * 0.15))
        }

        // ---- 2. Dedos, de meñique a pulgar ----
        let chains: [[VNHumanHandPoseObservation.JointName]] = [
            [.littleMCP, .littlePIP, .littleDIP, .littleTip],
            [.ringMCP, .ringPIP, .ringDIP, .ringTip],
            [.middleMCP, .middlePIP, .middleDIP, .middleTip],
            [.indexMCP, .indexPIP, .indexDIP, .indexTip]
        ]

        // Recorrido: sube por el lado cubital del dedo, rodea la yema y baja por el radial.
        for (order, chain) in chains.enumerated() {
            let pts = chain.compactMap { joints[$0] }
            guard pts.count >= 2 else { continue }
            let radii = fingerRadii(fingerIndex: 4 - order, scale: scale, count: pts.count)

            appendFinger(contour: &contour, points: pts, radii: radii,
                         entrySide: ulnar, exitSide: radial,
                         radial: radial, side: 1.0)

            // Muesca en V hacia el dedo siguiente.
            if order < chains.count - 1,
               let a = pts.first,
               let nextChain = chains.indices.contains(order + 1) ? chains[order + 1].last : nil,
               let b = joints[nextChain] {
                let web = CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
                let towardWrist = CGPoint(x: wrist.x - web.x, y: wrist.y - web.y)
                let wl = max(hypot(towardWrist.x, towardWrist.y), 0.001)
                let depth = scale * 0.16
                contour.append(CGPoint(x: web.x + towardWrist.x / wl * depth,
                                       y: web.y + towardWrist.y / wl * depth))
            }
        }

        // ---- 3. Pulgar: sube por el lado cubital, punta, baja por el radial ----
        let thumbChain: [VNHumanHandPoseObservation.JointName] = [.thumbCMC, .thumbMP, .thumbIP, .thumbTip]
        let thumbPts = thumbChain.compactMap { joints[$0] }
        if thumbPts.count >= 2 {
            // Muesca entre índice y pulgar (más profunda, primer interóseo dorsal).
            if let indexMCP = joints[.indexMCP] {
                let web = CGPoint(x: (thumbPts[0].x + indexMCP.x) * 0.5,
                                  y: (thumbPts[0].y + indexMCP.y) * 0.5)
                let towardWrist = CGPoint(x: wrist.x - web.x, y: wrist.y - web.y)
                let wl = max(hypot(towardWrist.x, towardWrist.y), 0.001)
                contour.append(CGPoint(x: web.x + towardWrist.x / wl * scale * 0.20,
                                       y: web.y + towardWrist.y / wl * scale * 0.20))
            }
            let radii = fingerRadii(fingerIndex: 0, scale: scale, count: thumbPts.count)
            appendFinger(contour: &contour, points: thumbPts, radii: radii,
                         entrySide: ulnar, exitSide: radial,
                         radial: radial, side: 1.0)
        }

        // ---- 4. Borde radial (tenar) de la palma: pulgar → muñeca ----
        let radialStart = offset(wrist, radial, wristRadius)
        contour.append(offset(CGPoint(x: (wrist.x + (joints[.indexMCP]?.x ?? wrist.x)) * 0.5,
                                      y: (wrist.y + (joints[.indexMCP]?.y ?? wrist.y)) * 0.5),
                              radial, scale * 0.26))
        contour.append(radialStart)

        // ---- 5. Antebrazo: baja por el radial, rodea el extremo y sube por el cubital ----
        let elbow = CGPoint(x: wrist.x + armDir.x * armLen, y: wrist.y + armDir.y * armLen)
        let armRadius = scale * 0.28
        let perp = CGPoint(x: -armDir.y, y: armDir.x)

        // Lado radial del antebrazo
        appendLine(&contour, from: radialStart,
                   to: CGPoint(x: elbow.x - perp.x * armRadius, y: elbow.y - perp.y * armRadius),
                   steps: 3)

        // Extremo del brazo (semicírculo) — queda oculto por el fade de la máscara.
        let capAngleStart = atan2(-perp.y, -perp.x)
        let capAngleEnd = atan2(perp.y, perp.x)
        appendArc(&contour, center: elbow, radius: armRadius,
                  from: capAngleStart, to: capAngleEnd, clockwise: true, steps: 8)

        // Lado cubital del antebrazo de vuelta a la muñeca
        appendLine(&contour, from: CGPoint(x: elbow.x + perp.x * armRadius, y: elbow.y + perp.y * armRadius),
                   to: ulnarStart, steps: 3)

        guard contour.count >= 8 else { group.clear(); return }

        // ---- 6. Construir el path con winding positivo (sin huecos) ----
        let path = CGMutablePath()
        let ordered = positiveWinding(contour)
        path.move(to: ordered[0])
        for i in 1..<ordered.count { path.addLine(to: ordered[i]) }
        path.closeSubpath()

        // Máscara de desvanecido a lo largo del antebrazo (de la muñeca hacia el codo).
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let maskFrom = CGPoint(x: wrist.x - armDir.x * (scale * 0.55),
                               y: wrist.y - armDir.y * (scale * 0.55))
        let maskTo = CGPoint(x: wrist.x + armDir.x * (armLen * 0.92),
                             y: wrist.y + armDir.y * (armLen * 0.92))
        group.wristMask.startPoint = CGPoint(x: maskFrom.x / w, y: maskFrom.y / h)
        group.wristMask.endPoint = CGPoint(x: maskTo.x / w, y: maskTo.y / h)

        // Grosor del contorno según profundidad real (más cerca = línea algo más marcada).
        let depthFactor = CGFloat(min(max(0.65 / max(CGFloat(pose.depthMeters), 0.10), 0.75), 1.8))
        group.outlineLayer.lineWidth = 1.55 * depthFactor
        group.outlineLayer.strokeColor = UIColor(white: 0.93, alpha: 0.92).cgColor
        group.fillLayer.fillColor = UIColor(white: 0.115, alpha: 0.58).cgColor

        group.fillLayer.path = path
        group.fillLayer.shadowColor = UIColor.black.cgColor
        group.fillLayer.shadowOpacity = 0.0
        group.outlineLayer.path = path

        // Sombra de contacto desplazada: sensación de volumen sobre el escenario.
        let shadowPath = CGMutablePath()
        shadowPath.addPath(path, transform: CGAffineTransform(translationX: 3, y: 6))
        group.shadowLayer.path = shadowPath
        group.shadowLayer.fillColor = UIColor.black.withAlphaComponent(0.24).cgColor
        group.shadowLayer.compositingFilter = nil
    }

    // MARK: - Dedos

    private func fingerRadii(fingerIndex: Int, scale: CGFloat, count: Int) -> [CGFloat] {
        let defs = HandTracker.boneDefinitions
            .filter { $0.fingerIndex == fingerIndex }
            .sorted { $0.segmentIndex < $1.segmentIndex }
        var radii = defs.map { scale * $0.radiusStartRatio }
        if let last = defs.last { radii.append(scale * last.radiusEndRatio) }
        while radii.count < count { radii.append(radii.last ?? scale * 0.1) }
        if radii.count > count { radii = Array(radii.prefix(count - 1)) + [radii[count - 1]] }
        return radii
    }

    /// Añade al contorno un dedo completo: lado de entrada → punta redondeada → lado de salida.
    private func appendFinger(contour: inout [CGPoint],
                              points: [CGPoint],
                              radii: [CGFloat],
                              entrySide: CGPoint,
                              exitSide: CGPoint,
                              radial: CGPoint,
                              side: CGFloat) {
        guard points.count >= 2, radii.count >= 2 else { return }
        _ = radial
        _ = side

        // Lado de entrada (de la base hacia la punta).
        for i in 0..<points.count {
            contour.append(offset(points[i], entrySide, radii[min(i, radii.count - 1)]))
        }

        // Punta: semicírculo del lado de entrada al de salida.
        let tip = points[points.count - 1]
        let prev = points[points.count - 2]
        let dirAngle = atan2(tip.y - prev.y, tip.x - prev.x)

        // Ángulos absolutos de cada lado en la punta.
        let entryAngle = angleOfVector(entrySide)
        let exitAngle = angleOfVector(exitSide)

        let rTip = radii[radii.count - 1] * 0.95
        appendArc(&contour, center: tip, radius: rTip,
                  from: entryAngle, to: exitAngle,
                  clockwise: false, steps: 7,
                  referenceDirection: dirAngle)

        // Lado de salida (de la punta hacia la base).
        for i in stride(from: points.count - 1, through: 0, by: -1) {
            contour.append(offset(points[i], exitSide, radii[min(i, radii.count - 1)]))
        }
    }

    private func angleOfVector(_ v: CGPoint) -> CGFloat {
        atan2(v.y, v.x)
    }

    // MARK: - Primitivas

    private func offset(_ p: CGPoint, _ dir: CGPoint, _ r: CGFloat) -> CGPoint {
        CGPoint(x: p.x + dir.x * r, y: p.y + dir.y * r)
    }

    private func appendLine(_ contour: inout [CGPoint], from a: CGPoint, to b: CGPoint, steps: Int) {
        let safeSteps = max(steps, 1)
        for i in 1...safeSteps {
            let t = CGFloat(i) / CGFloat(safeSteps)
            contour.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
    }

    /// Añade puntos de arco tomando el camino más corto entre los dos ángulos.
    private func appendArc(_ contour: inout [CGPoint],
                           center: CGPoint,
                           radius: CGFloat,
                           from startAngle: CGFloat,
                           to endAngle: CGFloat,
                           clockwise: Bool,
                           steps: Int,
                           referenceDirection: CGFloat? = nil) {
        var delta = endAngle - startAngle
        while delta <= -.pi { delta += .pi * 2 }
        while delta > .pi { delta -= .pi * 2 }

        // La punta tiene que abombarse en la dirección del dedo: si el punto medio del
        // arco no coincide con esa dirección, se recorre por el otro lado.
        if let ref = referenceDirection {
            let outward = normalizeAngle(ref - (startAngle + delta * 0.5))
            if abs(outward) > .pi * 0.45 {
                delta = delta > 0 ? delta - .pi * 2 : delta + .pi * 2
            }
        }
        _ = clockwise

        let safeSteps = max(steps, 3)
        for i in 0...safeSteps {
            let t = CGFloat(i) / CGFloat(safeSteps)
            let a = startAngle + delta * t
            contour.append(CGPoint(x: center.x + cos(a) * radius,
                                   y: center.y + sin(a) * radius))
        }
    }

    private func normalizeAngle(_ a: CGFloat) -> CGFloat {
        var v = a
        while v <= -.pi { v += .pi * 2 }
        while v > .pi { v -= .pi * 2 }
        return v
    }

    private func positiveWinding(_ points: [CGPoint]) -> [CGPoint] {
        var area: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            area += (a.x * b.y - b.x * a.y)
        }
        return area >= 0 ? points : Array(points.reversed())
    }
}
