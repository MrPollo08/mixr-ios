import CoreGraphics
import Foundation
import QuartzCore
import simd

/// Eventos que el motor de gestos comunica a la sesión XR.
enum GestureEvent {
    /// Seleccionar / hacer clic (pinza corta sobre algo).
    case click(CGPoint)
    /// Desplazarse: pinza mantenida + movimiento de la mano.
    case scroll(CGPoint, CGSize)
    /// Tocar directamente con la yema del índice (sin pinza).
    case directTouch(CGPoint)
    /// Empezó / terminó de arrastrar una ventana.
    case grabBegan
    case grabEnded
}

/// Motor de gestos espaciales.
///
/// 1. **Seleccionar / clic** — pinza corta sobre algo.
/// 2. **Scroll** — pinza mantenida y desplazamiento de la mano.
/// 3. **Direct Touch** — la yema del índice toca la superficie de una ventana.
/// 4. **Mover ventanas** — pinza en el borde o en la barra lateral + arrastre 3D.
///
/// El arrastre se hace con la posición **3D de la mano en el mundo**, no con el
/// desplazamiento en pantalla: así la ventana sigue a la mano aunque muevas la cabeza
/// (la base de la cámara ya no se mezcla con el movimiento) y no se dispara.
final class GestureEngine {

    enum State {
        case idle
        case pinching(target: SpatialWindow?, start: CGPoint, at: CFTimeInterval)
        case scrolling(target: SpatialWindow?, last: CGPoint)
        case dragging(window: SpatialWindow)
    }

    var onEvent: ((GestureEvent) -> Void)?

    private var state: State = .idle
    private var lastSeenAt: CFTimeInterval = 0
    /// Tolerancia a micro-pérdidas de Vision durante un arrastre.
    private let grace: TimeInterval = 0.45

    /// Umbrales (puntos de pantalla).
    private let scrollThreshold: CGFloat = 13
    private let clickMaxDuration: CFTimeInterval = 0.45
    private let clickMaxTravel: CGFloat = 15

    /// Histéresis de pinza.
    private let pinchEnter: CGFloat = 0.62
    private let pinchExit: CGFloat = 0.40

    /// Se acepta **pinza pulgar-índice** *o* **puño cerrado**: agarrar una ventana como
    /// si fuera un objeto físico es con el puño, y era el gesto que no se detectaba.
    private func grabs(_ hand: HandPose) -> Bool {
        hand.pinch >= pinchEnter || hand.closedFist
    }

    private func holds(_ hand: HandPose) -> Bool {
        hand.pinch >= pinchExit || hand.closedFist
    }

    // Direct Touch
    private var touchLatched: [String: Bool] = [:]
    private var lastTouchEventAt: CFTimeInterval = 0

    // Arrastre 3D
    private var dragStartPoint: CGPoint = .zero
    private var dragStartPosition: simd_float3 = .zero
    private var dragStartHandWorld: simd_float3 = .zero
    private var dragHas3D = false
    /// Base congelada al agarrar (sólo se usa si el 3D no está disponible).
    private var dragRight: simd_float3 = simd_float3(1, 0, 0)
    private var dragUp: simd_float3 = simd_float3(0, 1, 0)
    private var dragPointsPerMeter: CGFloat = 600
    private var dragStartCamera: simd_float3 = .zero
    /// Suavizado adaptativo de la posición de la ventana mientras se arrastra.
    private var dragFilter = OneEuroFilter3D(minCutoffXY: 3.4, betaXY: 3.6,
                                             minCutoffZ: 1.4, betaZ: 1.0,
                                             dCutoff: 1.0)

    var isDragging: Bool {
        if case .dragging = state { return true }
        return false
    }

    func reset() {
        if case .dragging(let window) = state {
            window.view.setGrabbed(false)
            window.view.setGrabBar(near: false)
        }
        state = .idle
        touchLatched.removeAll()
        dragFilter.reset()
    }

    // MARK: - Ciclo por frame

    func update(poses: [HandPose], host: WindowHostView, pose: CameraPose) {
        let now = CACurrentMediaTime()
        let primary = poses.first

        // --- Direct Touch (yema apoyada sobre una ventana) ---
        handleDirectTouch(poses: poses, host: host, pose: pose, now: now)

        // HISTÉRESIS DE VERDAD: para *empezar* hace falta 0.62, pero para *seguir*
        // agarrando alcanza 0.40. Sin esto, el valor de pinza oscilaba alrededor del
        // umbral con el puño y el agarre se soltaba y re-enganchaba en cada frame:
        // resultado, la ventana se quedaba clavada donde estaba.
        let startPinching = poses.filter { grabs($0) }
        let holdingPinching = poses.filter { holds($0) }
        let pinching = state.isPinchingLike ? holdingPinching : startPinching
        let anyPinching = !pinching.isEmpty

        if !anyPinching && state.isPinchingLike {
            // Soltó la pinza.
            if case .pinching(let target, let start, let at) = state, let hand = primary {
                let travel = hypot(hand.pinchPoint.x - start.x, hand.pinchPoint.y - start.y)
                if now - at <= clickMaxDuration && travel <= clickMaxTravel {
                    let point = hand.pinchPoint
                    if let target, let press = target.pressAt, press(point) {
                        // El contenido ya consumió el clic.
                    } else if let target, let clickAt = target.clickAt {
                        _ = clickAt(point)
                    }
                    onEvent?(.click(point))
                }
            }
            if case .dragging(let window) = state {
                window.view.setGrabbed(false)
                window.view.setGrabBar(near: false)
                onEvent?(.grabEnded)
            }
            state = .idle
            return
        }

        switch state {
        case .idle:
            guard let hand = pinching.first else {
                updateHover(poses: poses, host: host)
                return
            }
            beginPinch(with: hand, host: host, pose: pose, now: now)

        case .pinching(let target, let start, let at):
            guard let hand = pinching.first else { return }
            lastSeenAt = now

            let travel = hypot(hand.pinchPoint.x - start.x, hand.pinchPoint.y - start.y)
            if travel > scrollThreshold, let target, target.scrollAt != nil {
                state = .scrolling(target: target, last: hand.pinchPoint)
                return
            }
            if now - at > clickMaxDuration, let target, target.scrollAt != nil {
                state = .scrolling(target: target, last: hand.pinchPoint)
            }

        case .scrolling(let target, let last):
            guard let hand = pinching.first else { return }
            lastSeenAt = now
            let delta = CGSize(width: hand.pinchPoint.x - last.x,
                               height: hand.pinchPoint.y - last.y)
            if abs(delta.height) + abs(delta.width) > 0.4, let target, let scroll = target.scrollAt {
                _ = scroll(hand.pinchPoint, delta)
                onEvent?(.scroll(hand.pinchPoint, delta))
            }
            state = .scrolling(target: target, last: hand.pinchPoint)

        case .dragging(let window):
            guard let hand = pinching.first else {
                // Micro-pérdida: se mantiene el agarre sin mover, así no salta.
                if now - lastSeenAt < grace { return }
                window.view.setGrabbed(false)
                window.view.setGrabBar(near: false)
                onEvent?(.grabEnded)
                state = .idle
                return
            }
            lastSeenAt = now
            moveWindow(window, with: hand, pose: pose, host: host)
        }
    }

    // MARK: - Inicio de pinza

    private func beginPinch(with hand: HandPose,
                            host: WindowHostView,
                            pose: CameraPose,
                            now: CFTimeInterval) {
        lastSeenAt = now

        // Borde o barra lateral → arrastrar (se amplió el margen para que sea fácil).
        if let byBar = host.window(atBar: hand.pinchPoint) {
            startDrag(window: byBar, with: hand, host: host, pose: pose)
            return
        }
        if let byBorder = host.window(nearBorder: hand.pinchPoint, margin: 72) {
            startDrag(window: byBorder, with: hand, host: host, pose: pose)
            return
        }
        if let tip = hand.joints[.indexTip],
           let byTipBorder = host.window(nearBorder: tip, margin: 72) {
            startDrag(window: byTipBorder, with: hand, host: host, pose: pose)
            return
        }

        // Si no hay borde: potencial clic o scroll sobre la ventana de debajo.
        let target = host.window(at: hand.pinchPoint) ?? host.window(near: hand.pinchPoint, margin: 24)
        state = .pinching(target: target, start: hand.pinchPoint, at: now)
        host.setGrabbed(target, grabbed: false)
    }

    private func startDrag(window: SpatialWindow,
                           with hand: HandPose,
                           host: WindowHostView,
                           pose: CameraPose) {
        dragStartPoint = hand.pinchPoint
        dragStartPosition = window.position

        let cols = pose.transform.columns
        dragStartCamera = simd_float3(cols.3.x, cols.3.y, cols.3.z)
        dragRight = Self.normalized(simd_float3(cols.0.x, cols.0.y, cols.0.z),
                                    fallback: simd_float3(1, 0, 0))
        dragUp = Self.normalized(simd_float3(cols.1.x, cols.1.y, cols.1.z),
                                 fallback: simd_float3(0, 1, 0))
        dragPointsPerMeter = window.pointsPerMeter > 1 ? window.pointsPerMeter : 600

        // Posición 3D de la mano al agarrar: es la referencia del arrastre.
        dragStartHandWorld = hand.pinchWorld3D
        dragHas3D = simd_length(hand.pinchWorld3D) > 0.0001
            && hand.jointsWorld3D[.thumbTip] != nil
            && hand.jointsWorld3D[.indexTip] != nil

        dragFilter.reset()

        host.bringToFront(window)
        host.setGrabbed(window, grabbed: true)
        state = .dragging(window: window)
        onEvent?(.grabBegan)
    }

    /// Arrastre: la ventana sigue el desplazamiento **3D de la mano en el mundo**.
    /// La profundidad va amortiguada porque el LiDAR en Z es mucho más ruidoso que X/Y.
    private func moveWindow(_ window: SpatialWindow,
                            with hand: HandPose,
                            pose: CameraPose,
                            host: WindowHostView) {

        var target: simd_float3

        if dragHas3D, simd_length(hand.pinchWorld3D) > 0.0001 {
            var delta = hand.pinchWorld3D - dragStartHandWorld
            delta.z *= 0.35

            // Tope de seguridad: si el salto es absurdo, se recorta.
            let maxDelta = Float(Config.maxWindowDistance)
            let jump = simd_length(delta)
            if jump > maxDelta {
                delta *= maxDelta / jump
            }

            target = dragStartPosition + delta
        } else {
            // Respaldo 2D con la base de cámara **congelada al agarrar**: mover la cabeza
            // ya no inyecta movimiento en la ventana.
            let dx = hand.pinchPoint.x - dragStartPoint.x
            let dy = hand.pinchPoint.y - dragStartPoint.y
            let metersPerPoint = 1 / dragPointsPerMeter
            let lateral = dragRight * Float(dx) * Float(metersPerPoint)
                + dragUp * Float(-dy) * Float(metersPerPoint)
            target = dragStartPosition + lateral
        }

        // No se aleja/acerca más allá de los límites desde la cámara.
        let toTarget = target - dragStartCamera
        let distance = simd_length(toTarget)
        if distance > Float(Config.maxWindowDistance) {
            target = dragStartCamera + toTarget * (Float(Config.maxWindowDistance) / distance)
        } else if distance < Float(Config.minWindowDistance) {
            target = dragStartCamera + Self.normalized(toTarget, fallback: simd_float3(0, 0, -1))
                * Float(Config.minWindowDistance)
        }

        let smoothed = dragFilter.filter(target)
        host.setPosition(window, smoothed, force: true)
    }

    private static func normalized(_ v: simd_float3, fallback: simd_float3) -> simd_float3 {
        let len = simd_length(v)
        return len > 1e-4 ? (v / len) : fallback
    }

    // MARK: - Direct Touch

    private func handleDirectTouch(poses: [HandPose],
                                   host: WindowHostView,
                                   pose: CameraPose,
                                   now: CFTimeInterval) {
        guard now - lastTouchEventAt > 0.10 else { return }

        for hand in poses {
            guard let tip2D = hand.joints[.indexTip],
                  let tip3D = hand.jointsWorld3D[.indexTip] else { continue }

            var best: SpatialWindow?
            var bestDistance: Float = .greatestFiniteMagnitude
            var bestPoint: CGPoint = .zero

            for window in host.windows where !window.view.isHidden {
                guard let frame = host.screenFrame(for: window) else { continue }
                guard frame.insetBy(dx: -10, dy: -10).contains(tip2D) else { continue }

                let toTip = tip3D - window.position
                let depthGap = abs(simd_dot(toTip, simd_normalize(window.normal)))
                if depthGap < bestDistance {
                    bestDistance = depthGap
                    best = window
                    bestPoint = tip2D
                }
            }

            guard let window = best else {
                touchLatched[hand.key] = false
                continue
            }

            let touching = bestDistance <= 0.035
            if touching, touchLatched[hand.key] != true {
                touchLatched[hand.key] = true
                lastTouchEventAt = now
                if let press = window.pressAt, press(bestPoint) {
                    onEvent?(.directTouch(bestPoint))
                } else if let clickAt = window.clickAt {
                    _ = clickAt(bestPoint)
                    onEvent?(.directTouch(bestPoint))
                } else {
                    onEvent?(.directTouch(bestPoint))
                }
            } else if bestDistance > 0.075 {
                touchLatched[hand.key] = false
            }
        }
    }

    // MARK: - Hover

    private func updateHover(poses: [HandPose], host: WindowHostView) {
        let dt = CGFloat(1.0 / 60.0)
        guard let hand = poses.first else {
            for w in host.windows where w.hoverAt != nil { w.hoverAt?(nil, dt) }
            return
        }
        let pointer = hand.joints[.indexTip] ?? hand.pinchPoint

        for window in host.windows where window.hoverAt != nil {
            guard !window.view.isHidden else { continue }
            if window.view.frame.insetBy(dx: -30, dy: -30).contains(pointer) {
                window.hoverAt?(pointer, dt)
            } else {
                window.hoverAt?(nil, dt)
            }
        }

        for window in host.windows {
            window.view.setGrabBar(near: host.grabBarRect(for: window).contains(pointer))
        }
    }
}

private extension GestureEngine.State {
    var isPinchingLike: Bool {
        switch self {
        case .pinching, .scrolling, .dragging: return true
        case .idle: return false
        }
    }
}
