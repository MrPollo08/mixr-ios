import CoreGraphics
import Foundation

/// Traduce el pellizco de las manos en arrastrar y escalar ventanas.
///
/// - Una mano en pinza sobre una ventana: la agarra y la mueve por el mundo.
/// - Dos manos en pinza: separarlas agranda la ventana, juntarlas la achica.
final class GestureEngine {

    private var dragged: SpatialWindow?
    private var anchor: CGPoint = .zero
    private var resizeSpan: CGFloat?
    private var resizeStartWidth: CGFloat = 0
    private var latch: [String: Bool] = [:]

    var isDragging: Bool { dragged != nil }

    func reset() {
        dragged = nil
        resizeSpan = nil
        latch.removeAll()
    }

    func update(poses: [HandPose], host: WindowHostView) {
        guard let camera = host.lastCamera else { return }

        var pinching: [HandPose] = []
        var activeKeys = Set<String>()

        for pose in poses {
            activeKeys.insert(pose.key)
            let wasPinching = latch[pose.key] ?? false
            // Histéresis: cuesta más empezar que mantener (evita parpadeos).
            let threshold: CGFloat = wasPinching ? 0.55 : 0.78
            let isPinching = pose.pinch > threshold
            latch[pose.key] = isPinching
            if isPinching { pinching.append(pose) }
        }

        for key in Array(latch.keys) where !activeKeys.contains(key) {
            latch[key] = nil
        }

        guard let window = dragged else {
            if let first = pinching.first, let target = host.window(at: first.pinchPoint) {
                dragged = target
                anchor = first.pinchPoint
                resizeSpan = nil
                host.bringToFront(target)
            }
            return
        }

        if pinching.isEmpty {
            dragged = nil
            resizeSpan = nil
            return
        }

        if pinching.count >= 2 {
            let span = distance(pinching[0].pinchPoint, pinching[1].pinchPoint)
            guard let start = resizeSpan else {
                resizeSpan = span
                resizeStartWidth = window.physicalWidth
                anchor = pinching[0].pinchPoint
                return
            }
            if start > 4 {
                let factor = span / start
                let width = resizeStartWidth * factor
                host.setWidth(window,
                              meters: min(max(width, Config.minWindowWidth), Config.maxWindowWidth))
            }
        } else {
            // Si venía de dos manos, reengancha el arrastre sin dar un salto.
            if resizeSpan != nil {
                resizeSpan = nil
                anchor = pinching[0].pinchPoint
                return
            }
            let point = pinching[0].pinchPoint
            host.move(window, dx: point.x - anchor.x, dy: point.y - anchor.y, camera: camera)
            anchor = point
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
