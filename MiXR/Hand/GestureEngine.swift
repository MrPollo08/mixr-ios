import CoreGraphics
import Foundation
import QuartzCore

/// Traduce el pellizco de las manos en arrastrar y escalar ventanas.
///
/// Reglas de la versión "que no arrastre mal":
///  - El ancla del arrastre es la **yema del índice**, no el punto medio de la
///    pinza (ese se mueve solo cuando cerrás los dedos y hacía temblar todo).
///  - El desplazamiento es **absoluto** respecto del punto donde agarraste, así
///    no se acumula error ni se va "arrastrando" solo.
///  - Si Vision pierde la mano un instante, hay 300 ms de gracia: no se suelta.
///  - Dos manos en pinza escalan; al soltar una, se reengancha sin salto.
final class GestureEngine {

    private var grabbed: SpatialWindow?
    private var dragKey: String?
    private var startPoint: CGPoint = .zero
    private var applied: CGSize = .zero
    private var lastSeenAt: CFTimeInterval = 0

    private var resizing = false
    private var resizeSpan: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0

    private var latch: [String: Bool] = [:]
    private let grace: TimeInterval = 0.30

    var isDragging: Bool { grabbed != nil }

    func reset() {
        grabbed = nil
        dragKey = nil
        resizing = false
        latch.removeAll()
    }

    func update(poses: [HandPose], host: WindowHostView) {
        guard let pose = host.lastPose else { return }
        let now = CACurrentMediaTime()

        // 1. Pinza por mano, con histéresis (cuesta empezar, se mantiene fácil).
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

        // 2. Sin ventana agarrada: ver si la pinza cae sobre alguna.
        guard let window = grabbed else {
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

        // 4. Dos manos en pinza: escalar.
        if pinching.count >= 2 {
            let a = dragPoint(pinching[0])
            let b = dragPoint(pinching[1])
            let span = hypot(a.x - b.x, a.y - b.y)

            if !resizing {
                resizing = true
                resizeSpan = span
                resizeStartWidth = window.physicalWidth
            } else if resizeSpan > 4 {
                let width = resizeStartWidth * (span / resizeSpan)
                host.setWidth(window, meters: min(max(width, Config.minWindowWidth), Config.maxWindowWidth))
            }
            return
        }

        // 5. Volvió a una sola mano: reenganchar sin que pegue un salto.
        if resizing {
            resizing = false
            begin(window: window, with: owner, host: host)
            return
        }

        // 6. Arrastre: delta absoluto desde el punto de agarre.
        let point = dragPoint(owner)
        let total = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
        let delta = CGSize(width: total.width - applied.width, height: total.height - applied.height)

        if abs(delta.width) > 0.02 || abs(delta.height) > 0.02 {
            host.move(window, dx: delta.width, dy: delta.height, pose: pose)
            applied = total
        }
    }

    // MARK: - Agarre

    private func begin(window: SpatialWindow, with hand: HandPose, host: WindowHostView) {
        grabbed = window
        dragKey = hand.key
        startPoint = dragPoint(hand)
        applied = .zero
        resizing = false
        lastSeenAt = CACurrentMediaTime()
        host.bringToFront(window)
        host.setGrabbed(window, grabbed: true)
    }

    private func end(host: WindowHostView) {
        if let window = grabbed {
            host.setGrabbed(window, grabbed: false)
        }
        grabbed = nil
        dragKey = nil
        resizing = false
    }

    /// Punto de control: la yema del índice (estable) y si no, la pinza.
    private func dragPoint(_ hand: HandPose) -> CGPoint {
        hand.joints[.indexTip] ?? hand.pinchPoint
    }
}
