import CoreGraphics
import Foundation
import QuartzCore
import simd

/// Traduce el pellizco de las manos en mover, estirar y acercar/alejar ventanas.
///
/// Reglas:
///  - El ancla es la **yema del índice** (estable), no el punto medio de la pinza.
///  - Cuerpo de la ventana  → arrastre en el plano (izquierda/derecha/arriba/abajo).
///  - **Costado** de la ventana → estirar: el borde sigue a la mano y la ventana
///    crece o se achica (tirás hacia afuera y se agranda).
///  - Acercar la mano a la cámara mientras arrastrás → la ventana **se acerca**
///    (usa el tamaño aparente de la mano como sensor de profundidad).
///  - Dos manos en pinza → escala libre.
///  - 300 ms de gracia si Vision pierde la mano.
final class GestureEngine {

    private enum Mode {
        case translate
        case stretch
    }

    private var grabbed: SpatialWindow?
    private var dragKey: String?
    private var mode: Mode = .translate

    private var startPoint: CGPoint = .zero
    private var startPosition: simd_float3 = .zero
    private var startPointsPerMeter: CGFloat = 0
    private var startHandSize: CGFloat = 0
    private var applied: CGSize = .zero

    private var depthRatio: Float = 1
    private var stretchOffset: CGFloat = 0

    private var lastSeenAt: CFTimeInterval = 0

    private var twoHandResize = false
    private var resizeSpan: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0

    private var latch: [String: Bool] = [:]
    private let grace: TimeInterval = 0.30

    var isDragging: Bool { grabbed != nil }

    func reset() {
        grabbed = nil
        dragKey = nil
        twoHandResize = false
        latch.removeAll()
    }

    func update(poses: [HandPose], host: WindowHostView) {
        guard let pose = host.lastPose else { return }
        let now = CACurrentMediaTime()

        // 1. Pinza por mano, con histéresis.
        var pinching: [HandPose] = []
        var activeKeys = Set<String>()
        for hand in poses {
            activeKeys.insert(hand.key)
            let wasPinching = latch[hand.key] ?? false
            let threshold: CGFloat = wasPinching ? 0.55 : 0.78
            let isPinching = hand.pinch > threshold
            latch[hand.key] = isPinching
            if isPinching { pinching.append(hand) }
        }
        for key in Array(latch.keys) where !activeKeys.contains(key) {
            latch[key] = nil
        }

        // 2. Sin ventana agarrada: resaltar el menú y ver si la pinza cae en algo.
        guard let window = grabbed else {
            updateHover(poses: poses, host: host)
            if let first = pinching.first, let target = host.window(at: dragPoint(first)) {
                begin(window: target, with: first, host: host)
            }
            return
        }

        // 3. ¿Sigue la misma mano pellizcando?
        guard let owner = pinching.first(where: { $0.key == dragKey }) else {
            if now - lastSeenAt < grace { return }
            end(host: host)
            return
        }
        lastSeenAt = now

        // 4. Dos manos en pinza: escala libre.
        if pinching.count >= 2 {
            let a = dragPoint(pinching[0])
            let b = dragPoint(pinching[1])
            let span = hypot(a.x - b.x, a.y - b.y)

            if !twoHandResize {
                twoHandResize = true
                resizeSpan = span
                resizeStartWidth = window.physicalWidth
            } else if resizeSpan > 4 {
                let width = resizeStartWidth * (span / resizeSpan)
                host.setWidth(window, meters: min(max(width, Config.minWindowWidth), Config.maxWindowWidth))
            }
            return
        }

        // 5. Volvió a una sola mano: reenganchar sin salto.
        if twoHandResize {
            twoHandResize = false
            begin(window: window, with: owner, host: host)
            return
        }

        let point = dragPoint(owner)

        switch mode {
        case .stretch:
            stretch(window, to: point, host: host)
        case .translate:
            translate(window, with: owner, to: point, pose: pose, host: host)
        }
    }

    // MARK: - Arrastre + profundidad

    private func translate(_ window: SpatialWindow,
                           with hand: HandPose,
                           to point: CGPoint,
                           pose: CameraPose,
                           host: WindowHostView) {
        let total = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
        applied = total

        let pointsPerMeter = startPointsPerMeter > 1 ? startPointsPerMeter : window.pointsPerMeter
        guard pointsPerMeter > 1 else { return }

        let transform = pose.transform
        let right = simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let camera = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        // Desplazamiento lateral en metros (constante respecto del agarre).
        let lateral = right * Float(total.width / pointsPerMeter)
            + up * Float(-total.height / pointsPerMeter)

        // Profundidad: si la mano se agranda (se acerca), la ventana se acerca.
        let size = handSize(of: hand)
        if startHandSize > 4, size > 4 {
            let raw = Float(startHandSize / size)
            let clamped = min(max(raw, 0.55), 1.85)
            if abs(clamped - 1) > 0.03 || abs(depthRatio - 1) > 0.03 {
                depthRatio += (clamped - depthRatio) * 0.2
            }
        }

        let base = startPosition + lateral
        let position = camera + (base - camera) * depthRatio
        host.setPosition(window, position)
    }

    // MARK: - Estirar desde el costado

    private func stretch(_ window: SpatialWindow, to point: CGPoint, host: WindowHostView) {
        let center = host.center(of: window)
        let halfDistance = abs(point.x - center.x) + stretchOffset
        let meters = halfDistance * 2 / max(window.pointsPerMeter, 1)
        host.setWidth(window, meters: min(max(meters, Config.minWindowWidth), Config.maxWindowWidth))
    }

    // MARK: - Agarre

    private func begin(window: SpatialWindow, with hand: HandPose, host: WindowHostView) {
        let point = dragPoint(hand)

        // Si es el menú y la pinza cayó en un tile: apretar, no arrastrar.
        if let press = window.pressAt, press(point) {
            return
        }

        let zone = host.grabZone(for: window, at: point)

        grabbed = window
        dragKey = hand.key
        startPoint = point
        startPosition = window.position
        startPointsPerMeter = window.pointsPerMeter
        startHandSize = handSize(of: hand)
        applied = .zero
        depthRatio = 1
        twoHandResize = false
        lastSeenAt = CACurrentMediaTime()

        switch zone {
        case .body:
            mode = .translate
            stretchOffset = 0
        case .leftEdge, .rightEdge:
            mode = .stretch
            let halfWidth = window.physicalWidth * window.pointsPerMeter / 2
            let halfDistance = abs(point.x - host.center(of: window).x)
            stretchOffset = halfWidth - halfDistance
        }

        host.bringToFront(window)
        host.setGrabbed(window, grabbed: true)
    }

    private func end(host: WindowHostView) {
        if let window = grabbed {
            host.setGrabbed(window, grabbed: false)
        }
        grabbed = nil
        dragKey = nil
        twoHandResize = false
        depthRatio = 1
    }

    /// Resalta el tile del menú que está debajo del dedo (sin apretar).
    private func updateHover(poses: [HandPose], host: WindowHostView) {
        guard let menu = host.windows.first(where: { $0.pressAt != nil }) else { return }
        let tip: CGPoint? = poses.first.map { $0.joints[.indexTip] ?? $0.pinchPoint }
        menu.hoverAt?(tip)
    }

    /// Punto de control: la yema del índice (estable) y si no, la pinza.
    private func dragPoint(_ hand: HandPose) -> CGPoint {
        hand.joints[.indexTip] ?? hand.pinchPoint
    }

    /// Tamaño aparente de la mano en pantalla (crece cuando se acerca).
    private func handSize(of hand: HandPose) -> CGFloat {
        guard let wrist = hand.joints[.wrist], let middle = hand.joints[.middleMCP] else { return 0 }
        return hypot(wrist.x - middle.x, wrist.y - middle.y)
    }
}
