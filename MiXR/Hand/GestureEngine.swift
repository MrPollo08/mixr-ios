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
    /// Volver al menú universal (palma abierta mirando al teléfono + pinza).
    case universalMenu
    /// Tocar directamente con la yema del índice (sin pinza).
    case directTouch(CGPoint)
    /// Empezó / terminó de arrastrar una ventana.
    case grabBegan
    case grabEnded
}

/// Motor de gestos espaciales.
///
/// Los cinco gestos implementados:
/// 1. **Seleccionar / clic** — índice apuntando + pinza corta.
/// 2. **Scroll** — pinza mantenida y desplazamiento de la mano (suelta para cortar).
/// 3. **Menú universal** — palma abierta de frente + pinza.
/// 4. **Direct Touch** — la yema del índice toca la superficie de una ventana.
/// 5. **Mover ventanas** — pinza en el borde o en la barra lateral + arrastre 3D.
final class GestureEngine {

    enum State {
        case idle
        case pinching(target: SpatialWindow?, start: CGPoint, at: CFTimeInterval)
        case scrolling(target: SpatialWindow?, last: CGPoint)
        case dragging(window: SpatialWindow)
    }

    var onEvent: ((GestureEvent) -> Void)?

    private var state: State = .idle
    private var wasDragging = false
    private var lastSeenAt: CFTimeInterval = 0
    private let grace: TimeInterval = 0.30

    /// Umbrales (puntos de pantalla).
    private let scrollThreshold: CGFloat = 13
    private let clickMaxDuration: CFTimeInterval = 0.45
    private let clickMaxTravel: CGFloat = 15

    /// Histéresis de pinza.
    private let pinchEnter: CGFloat = 0.62
    private let pinchExit: CGFloat = 0.40

    // Direct Touch
    private var touchLatched: [String: Bool] = [:]
    private var lastTouchEventAt: CFTimeInterval = 0

    // Menú universal
    private var lastUniversalAt: CFTimeInterval = 0
    private var menuHoldSince: CFTimeInterval?
    private let universalCooldown: CFTimeInterval = 1.4
    /// Tiempo que hay que mantener "palma abierta + pinza" para evitar disparos falsos.
    private let menuHoldTime: CFTimeInterval = 0.30

    // Arrastre
    private var dragStartPoint: CGPoint = .zero
    private var dragStartPosition: simd_float3 = .zero
    private var dragStartWindowDepth: Float = 1.4
    private var appliedWindowDepth: Float = 1.4
    private var dragStartHandDepth: Float = 0.42
    private var dragStartCamera: simd_float3 = .zero
    private var dragForward: simd_float3 = simd_float3(0, 0, -1)

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
    }

    // MARK: - Ciclo por frame

    func update(poses: [HandPose], host: WindowHostView, pose: CameraPose) {
        let now = CACurrentMediaTime()
        let primary = poses.first

        // --- Gesto 3: menú universal (palma abierta de frente + pinza sostenida) ---
        var palmMenuActive = false
        for hand in poses where hand.isPalmFacingCamera && hand.isOpenHand && hand.pinch >= pinchEnter {
            palmMenuActive = true
            if menuHoldSince == nil { menuHoldSince = now }
            break
        }
        if palmMenuActive {
            if let since = menuHoldSince,
               now - since >= menuHoldTime,
               now - lastUniversalAt > universalCooldown {
                lastUniversalAt = now
                menuHoldSince = nil
                onEvent?(.universalMenu)
                reset()
                return
            }
        } else {
            menuHoldSince = nil
        }

        // --- Gesto 4: Direct Touch (yema apoyada sobre una ventana) ---
        handleDirectTouch(poses: poses, host: host, pose: pose, now: now)

        let pinching = poses.filter { $0.pinch >= pinchEnter }
        let anyPinching = !pinching.isEmpty

        if !anyPinching && state.isPinchingLike {
            // Soltó la pinza.
            if case .pinching(let target, let start, let at) = state, let hand = primary {
                let travel = hypot(hand.pinchPoint.x - start.x, hand.pinchPoint.y - start.y)
                if now - at <= clickMaxDuration && travel <= clickMaxTravel {
                    let point = hand.pinchPoint
                    if let target, let press = target.pressAt, press(point) {
                        // El menú ya consumió el clic.
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

            // ¿Se movió lo suficiente? → scroll (no clic).
            let travel = hypot(hand.pinchPoint.x - start.x, hand.pinchPoint.y - start.y)
            if travel > scrollThreshold, let target, target.scrollAt != nil {
                state = .scrolling(target: target, last: hand.pinchPoint)
                return
            }
            if now - at > clickMaxDuration, let target, target.scrollAt != nil {
                // Mantener la pinza sobre algo desplazable entra en modo scroll.
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

        // Gesto 5: borde o barra lateral → arrastrar la ventana.
        if let byBar = host.window(atBar: hand.pinchPoint) {
            startDrag(window: byBar, with: hand, host: host, pose: pose)
            return
        }
        if let byBorder = host.window(nearBorder: hand.pinchPoint) {
            startDrag(window: byBorder, with: hand, host: host, pose: pose)
            return
        }

        // Dedo índice apuntando sobre el borde de una ventana → también arrastra.
        if let tip = hand.joints[.indexTip], let byTipBorder = host.window(nearBorder: tip) {
            startDrag(window: byTipBorder, with: hand, host: host, pose: pose)
            return
        }

        // Si no hay borde: es un potencial clic o scroll sobre la ventana de debajo.
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
        dragStartHandDepth = hand.depthMeters

        let cols = pose.transform.columns
        dragStartCamera = simd_float3(cols.3.x, cols.3.y, cols.3.z)
        dragForward = -simd_float3(cols.2.x, cols.2.y, cols.2.z)

        if let proj = pose.project(window.position) {
            dragStartWindowDepth = proj.depth
            appliedWindowDepth = proj.depth
        } else {
            let d = max(simd_distance(window.position, dragStartCamera), 0.8)
            dragStartWindowDepth = d
            appliedWindowDepth = d
        }

        host.bringToFront(window)
        host.setGrabbed(window, grabbed: true)
        state = .dragging(window: window)
        onEvent?(.grabBegan)
    }

    private func moveWindow(_ window: SpatialWindow,
                            with hand: HandPose,
                            pose: CameraPose,
                            host: WindowHostView) {
        let pointsPerMeter = window.pointsPerMeter > 1 ? window.pointsPerMeter : 600
        let dx = hand.pinchPoint.x - dragStartPoint.x
        let dy = hand.pinchPoint.y - dragStartPoint.y

        let transform = pose.transform
        let right = simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let lateral = right * Float(dx / pointsPerMeter) + up * Float(-dy / pointsPerMeter)

        // Profundidad real con LiDAR: empujar/traer la mano acerca o aleja la ventana.
        if hand.hasLiDAR, dragStartHandDepth > 0.10, hand.depthMeters > 0.10 {
            let push = dragStartHandDepth - hand.depthMeters
            if abs(push) > 0.020 {
                let target = dragStartWindowDepth - push * Float(Config.windowDepthGain)
                let clamped = min(max(target, Float(Config.minWindowDistance)), Float(Config.maxWindowDistance))
                appliedWindowDepth += (clamped - appliedWindowDepth) * 0.20
            }
        }

        let depthShift = dragForward * (appliedWindowDepth - dragStartWindowDepth)
        host.setPosition(window, dragStartPosition + lateral + depthShift, force: true)
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

                // Distancia real (metros) entre la yema y el plano del panel.
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

    // MARK: - Hover del dedo sobre el menú

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
