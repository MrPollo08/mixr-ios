import CoreGraphics
import Foundation
import QuartzCore
import simd

/// Traduce el pellizco de las manos en mover y escalar ventanas.
///
/// - **Pinza** sobre una ventana → la mueve (y acercando la mano a la cámara la
///   ventana se acerca; alejándola, se va).
/// - **Dos manos** en pinza → escala (separar agranda, juntar achica).
/// - 300 ms de gracia si Vision pierde la mano, así no se suelta a mitad de camino.
/// - Sobre el menú, la pinza **aprieta el tile** en vez de arrastrar.
final class GestureEngine {

    private var grabbed: SpatialWindow?
    private var dragKey: String?

    private var startPoint: CGPoint = .zero
    private var startPosition: simd_float3 = .zero
    private var startCamera: simd_float3 = .zero
    private var startPointsPerMeter: CGFloat = 0
    private var startHandSize: CGFloat = 0
    private var startDepth: Float = 0
    private var depthRatio: Float = 1
    private var applied: CGSize = .zero
    private var lastPoint: CGPoint?
    private var lastSeenAt: CFTimeInterval = 0

    private var twoHandResize = false
    private var resizeSpan: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0

    private var latch: [String: Bool] = [:]
    private var lastHoverAt: CFTimeInterval = 0
    private let grace: TimeInterval = 0.45

    var isDragging: Bool { grabbed != nil }

    /// Se dispara con **doble pinza al aire** (sin tocar ninguna ventana):
    /// sirve para traer el menú cuando se perdió de vista.
    var onSummon: (() -> Void)?
    /// Palma abierta mantenida: abre o cierra el menú.
    var onPalm: (() -> Void)?
    private var palmSince: CFTimeInterval = 0
    private var palmFired = false

    private var lastTapAt: CFTimeInterval = 0
    private var lastTapPoint: CGPoint?

    func reset() {
        grabbed = nil
        dragKey = nil
        twoHandResize = false
        latch.removeAll()
    }

    func update(poses: [HandPose], host: WindowHostView, handDepth: Float? = nil) {
        guard let pose = host.lastPose else { return }
        let now = CACurrentMediaTime()

        // 1. Pinza por mano, con histéresis.
        var pinching: [HandPose] = []
        var activeKeys = Set<String>()
        var emptyRising: [CGPoint] = []

        for hand in poses {
            activeKeys.insert(hand.key)
            let wasPinching = latch[hand.key] ?? false
            let threshold: CGFloat = wasPinching ? 0.55 : 0.78
            let isPinching = hand.pinch > threshold
            latch[hand.key] = isPinching
            if isPinching { pinching.append(hand) }

            // Pinza nueva en el aire (no sobre una ventana) => posible "toque".
            if isPinching, !wasPinching, grabbed == nil,
               host.window(at: dragPoint(hand)) == nil {
                emptyRising.append(dragPoint(hand))
            }
        }
        for key in Array(latch.keys) where !activeKeys.contains(key) {
            latch[key] = nil
        }

        if grabbed == nil {
            for point in emptyRising {
                if now - lastTapAt < 0.7,
                   let previous = lastTapPoint,
                   hypot(point.x - previous.x, point.y - previous.y) < 160 {
                    lastTapAt = 0
                    lastTapPoint = nil
                    onSummon?()
                } else {
                    lastTapAt = now
                    lastTapPoint = point
                }
            }
        }

        // 2. Sin ventana agarrada: resaltar el menú y ver si la pinza cae en algo.
        // Palma abierta 0.7 s => abre o cierra el menú.
        if grabbed == nil, poses.contains(where: { $0.openPalm }) {
            if palmSince == 0 { palmSince = now }
            if !palmFired, now - palmSince > 0.7 {
                palmFired = true
                onPalm?()
            }
        } else {
            palmSince = 0
            palmFired = false
        }

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

        // 4. Dos manos en pinza: escala.
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

        // 6. Mover (y acercar/alejar con el tamaño aparente de la mano).
        translate(window, with: owner, to: dragPoint(owner), pose: pose, host: host, handDepth: handDepth)
    }

    // MARK: - Mover + profundidad

    private func translate(_ window: SpatialWindow,
                           with hand: HandPose,
                           to rawPoint: CGPoint,
                           pose: CameraPose,
                           host: WindowHostView,
                           handDepth: Float?) {

        // Predicción: las articulaciones vienen suavizadas, así que la ventana
        // llegaba tarde y se despegaba del recorrido del dedo.
        var point = rawPoint
        if let previous = lastPoint {
            let dx = rawPoint.x - previous.x
            let dy = rawPoint.y - previous.y
            if hypot(dx, dy) < 60 {
                point = CGPoint(x: rawPoint.x + dx * 0.55, y: rawPoint.y + dy * 0.55)
            }
        }
        lastPoint = rawPoint

        let total = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)

        // ppm actual: mantiene el 1:1 en pantalla aunque la ventana cambie de
        // profundidad a mitad del recorrido.
        let pointsPerMeter = window.pointsPerMeter > 1 ? window.pointsPerMeter : startPointsPerMeter
        guard pointsPerMeter > 1 else { return }

        let transform = pose.transform
        let right = simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)

        // Desplazamiento lateral en metros (respecto del punto de agarre).
        let lateral = right * Float(total.width / pointsPerMeter)
            + up * Float(-total.height / pointsPerMeter)

        // Profundidad: sólo si la mano está casi quieta en el plano. Si está
        // recorriendo, no se toca: así sigue el recorrido sin desviarse.
        let moved = hypot(total.width - applied.width, total.height - applied.height)

        if false /* una mano no cambia el tamaño: eso es con dos manos */ , moved < 2.0 {
            // 1) LiDAR: distancia real en metros (preciso).
            // 2) Respaldo: tamaño aparente de la mano.
            var raw: Float?
            if let handDepth, startDepth > 0.1 {
                raw = Float(CGFloat(startDepth) / CGFloat(handDepth))
            } else {
                let size = handSize(of: hand)
                if startHandSize > 4, size > 4 {
                    raw = Float(startHandSize / size)
                }
            }

            if let raw {
                let clamped = min(max(raw, 0.6), 1.7)
                if abs(clamped - 1) > 0.03 || abs(depthRatio - 1) > 0.03 {
                    depthRatio += (clamped - depthRatio) * (handDepth != nil ? 0.25 : 0.12)
                }
            }
        }
        applied = total

        let base = startPosition + lateral
        let position = startCamera + (base - startCamera) * depthRatio
        host.setPosition(window, position)
    }

    // MARK: - Agarre

    private func begin(window: SpatialWindow, with hand: HandPose, host: WindowHostView) {
        let point = dragPoint(hand)

        // El menú no se puede cerrar, pero sí mover: si la pinza cae en un tile,
        // se aprieta; si cae en el panel, se arrastra como cualquier ventana.
        // Pinza sobre un botón (menú/teclado) = clic del mouse virtual.
        if let press = window.pressAt, press(point) {
            return
        }

        grabbed = window
        dragKey = hand.key
        startPoint = point
        lastPoint = point
        startPosition = window.position
        if let cameraPose = host.lastPose {
            let column = cameraPose.transform.columns.3
            startCamera = simd_float3(column.x, column.y, column.z)
        } else {
            startCamera = .zero
        }
        startPointsPerMeter = window.pointsPerMeter
        startHandSize = handSize(of: hand)
        if let current = host.lastPose, let projection = current.project(window.position) {
            startDepth = projection.depth
        } else {
            startDepth = 0
        }
        depthRatio = 1
        twoHandResize = false
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
        twoHandResize = false
        depthRatio = 1
    }

    /// Resalta el tile del menú que está debajo del dedo y acumula el dwell.
    private func updateHover(poses: [HandPose], host: WindowHostView) {
        guard let menu = host.windows.first(where: { $0.pressAt != nil }) else { return }

        let now = CACurrentMediaTime()
        let dt = lastHoverAt == 0 ? 0 : CGFloat(min(0.1, now - lastHoverAt))
        lastHoverAt = now

        let tip: CGPoint? = poses.first.map { $0.joints[.indexTip] ?? $0.pinchPoint }
        menu.hoverAt?(tip, dt)
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
