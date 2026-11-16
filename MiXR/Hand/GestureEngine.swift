import CoreGraphics
import Foundation
import QuartzCore
import simd

/// Eventos que el motor de gestos comunica a la sesión XR.
enum GestureEvent {
    case click(CGPoint)
    case scroll(CGPoint, CGSize)
    case directTouch(CGPoint)
    case grabBegan
    case grabEnded
}

/// Motor de gestos **dirigido por eventos**, no por polling.
///
/// La diferencia clave: el toque se decide en el **instante del cruce del umbral**
/// (interpolado entre frames), no cuando la pinza termina. Eso es lo que elimina el
/// falso retraso — el evento existe en el momento en que la mano lo hace.
///
/// Se evalúa a la frecuencia de la pantalla con la pose ya suavizada/predicha, así que
/// no depende de que Vision entregue un frame justo en ese instante.
final class GestureEngine {

    var onEvent: ((GestureEvent) -> Void)?

    private let pinchEnter: CGFloat = 0.55
    private let pinchExit: CGFloat = 0.35
    /// Un toque válido: corto y sin desplazamiento.
    private let clickMaxDuration: CFTimeInterval = 0.55
    private let clickMaxTravel: CGFloat = 22
    /// Desplazamiento que convierte el agarre en scroll.
    private let scrollThreshold: CGFloat = 14
    private let grace: CFTimeInterval = 0.45

    private let pinchTracker = PinchTracker()
    /// Clasificador entrenado: decide *qué* gesto es. El `PinchTracker` decide *cuándo*.
    private let classifier = GestureClassifier()

    private var dragWindow: SpatialWindow?
    private var pressCandidate: SpatialWindow?
    private var pressStart: CGPoint = .zero
    private var pressStartedAt: CFTimeInterval = 0
    private var scrollTarget: SpatialWindow?
    private var scrollLastPoint: CGPoint = .zero
    private var lastSeenAt: CFTimeInterval = 0

    // Direct Touch
    private var touchLatched: [String: Bool] = [:]
    private var lastTouchEventAt: CFTimeInterval = 0

    // Arrastre 3D
    private var dragStartPoint: CGPoint = .zero
    private var dragStartPosition: simd_float3 = .zero
    private var dragStartHandWorld: simd_float3 = .zero
    private var dragHas3D = false
    private var dragRight: simd_float3 = simd_float3(1, 0, 0)
    private var dragUp: simd_float3 = simd_float3(0, 1, 0)
    private var dragPointsPerMeter: CGFloat = 600
    private var dragStartCamera: simd_float3 = .zero
    private var dragFilter = OneEuroFilter3D(minCutoffXY: 3.4, betaXY: 3.6,
                                             minCutoffZ: 1.4, betaZ: 1.0,
                                             dCutoff: 1.0)

    var isDragging: Bool { dragWindow != nil }

    /// Para el readout: si está agarrando en este frame.
    var isEngaged: Bool { dragWindow != nil || pressCandidate != nil }

    func reset() {
        dragWindow?.view.setGrabbed(false)
        dragWindow?.view.setGrabBar(near: false)
        dragWindow = nil
        pressCandidate = nil
        scrollTarget = nil
        pinchTracker.reset()
        classifier.reset()
        touchLatched.removeAll()
        dragFilter.reset()
    }

    // MARK: - Ciclo (se llama a la frecuencia de pantalla)

    func update(poses: [HandPose], host: WindowHostView, pose: CameraPose) {
        let now = CACurrentMediaTime()

        handleDirectTouch(poses: poses, host: host, pose: pose, now: now)

        guard let hand = poses.first else {
            // Sin mano: si hay arrastre activo se sostiene un instante y después se suelta.
            if dragWindow != nil, now - lastSeenAt > grace {
                endDrag()
            }
            updateHover(poses: poses, host: host)
            return
        }
        lastSeenAt = now

        let value = grabValue(hand)
        let crossing = pinchTracker.update(key: hand.key,
                                           value: value,
                                           point: hand.pinchPoint,
                                           time: now,
                                           enter: pinchEnter,
                                           exit: pinchExit)

        if let crossing {
            if crossing.isDown {
                handleDown(hand: hand,
                           at: crossing.point,
                           time: crossing.time,
                           host: host,
                           pose: pose)
            } else {
                handleUp(at: crossing.point, time: crossing.time)
            }
        }

        // Acciones continuas mientras el agarre está activo.
        if let window = dragWindow {
            moveWindow(window, with: hand, pose: pose, host: host)
        } else if let target = scrollTarget {
            let delta = CGSize(width: hand.pinchPoint.x - scrollLastPoint.x,
                               height: hand.pinchPoint.y - scrollLastPoint.y)
            if abs(delta.width) + abs(delta.height) > 0.3, let scroll = target.scrollAt {
                _ = scroll(hand.pinchPoint, delta)
                onEvent?(.scroll(hand.pinchPoint, delta))
            }
            scrollLastPoint = hand.pinchPoint
        } else if pressCandidate == nil {
            updateHover(poses: poses, host: host)
        }
    }

    // MARK: - Señal de agarre

    /// Pinza pulgar-índice **o** puño cerrado, en una sola señal continua.
    /// Fuente principal: el clasificador entrenado. Respaldo: la geometría.
    private func grabValue(_ hand: HandPose) -> CGFloat {
        if let features = GestureFeatureExtractor.features(for: hand) {
            classifier.classify(features: features)
            return CGFloat(classifier.grabProbability)
        }
        let pinch = pinchValue(hand)
        return hand.closedFist ? max(pinch, 0.85) : pinch
    }

    /// Para el readout: gesto reconocido y confianza.
    var recognizedGestureText: String {
        let label = classifier.lastGesture
        return String(format: "%@ %.2f", label.shortName, Double(classifier.lastConfidence))
    }

    /// Se recalcula en cada frame desde las articulaciones (ya suavizadas/predichas),
    /// así no depende de cuándo llegó el último frame de Vision.
    private func pinchValue(_ hand: HandPose) -> CGFloat {
        guard let thumb = hand.joints[.thumbTip],
              let index = hand.joints[.indexTip],
              let wrist = hand.joints[.wrist],
              let middle = hand.joints[.middleMCP] else {
            return hand.pinch
        }
        let palm = max(hypot(wrist.x - middle.x, wrist.y - middle.y), 8)
        let ratio = hypot(thumb.x - index.x, thumb.y - index.y) / palm
        return min(max(1 - ratio / 0.9, 0), 1)
    }

    // MARK: - Cruce hacia abajo: empezar

    private func handleDown(hand: HandPose,
                            at point: CGPoint,
                            time: CFTimeInterval,
                            host: WindowHostView,
                            pose: CameraPose) {
        // Borde o barra lateral → arrastrar.
        if let byBar = host.window(atBar: point) {
            startDrag(window: byBar, with: hand, host: host, pose: pose)
            return
        }
        if let byBorder = host.window(nearBorder: point, margin: 72) {
            startDrag(window: byBorder, with: hand, host: host, pose: pose)
            return
        }

        // Contenido → candidato a clic. Se da feedback **ya**, sin esperar al release.
        if let target = host.window(at: point) ?? host.window(near: point, margin: 20) {
            pressCandidate = target
            pressStart = point
            pressStartedAt = time
            scrollTarget = nil
            if let press = target.pressAt { _ = press(point) }
        }
    }

    // MARK: - Cruce hacia arriba: terminar

    private func handleUp(at point: CGPoint, time: CFTimeInterval) {
        if dragWindow != nil {
            endDrag()
            return
        }

        if let target = pressCandidate {
            let travel = hypot(point.x - pressStart.x, point.y - pressStart.y)
            let duration = time - pressStartedAt
            if scrollTarget == nil, duration <= clickMaxDuration, travel <= clickMaxTravel {
                if let clickAt = target.clickAt { _ = clickAt(point) }
                onEvent?(.click(point))
            }
        }

        pressCandidate = nil
        scrollTarget = nil
    }

    // MARK: - Arrastre

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

        dragStartHandWorld = hand.pinchWorld3D
        // El arrastre 3D dependía de la profundidad LiDAR de la pinza, que oscila y hacía
        // que la ventana se fuera "a cualquier lado". Se usa el camino 2D con la base de
        // cámara congelada: es rígido, 1:1 con el dedo y no puede dispararse.
        dragHas3D = false

        dragFilter.reset()
        pressCandidate = nil
        scrollTarget = nil

        host.bringToFront(window)
        host.setGrabbed(window, grabbed: true)
        dragWindow = window
        onEvent?(.grabBegan)
    }

    private func endDrag() {
        guard let window = dragWindow else { return }
        window.view.setGrabbed(false)
        window.view.setGrabBar(near: false)
        dragWindow = nil
        onEvent?(.grabEnded)
    }

    private func moveWindow(_ window: SpatialWindow,
                            with hand: HandPose,
                            pose: CameraPose,
                            host: WindowHostView) {
        var target: simd_float3

        if dragHas3D, simd_length(hand.pinchWorld3D) > 0.0001 {
            var delta = hand.pinchWorld3D - dragStartHandWorld
            delta.z *= 0.35

            let maxDelta = Float(Config.maxWindowDistance)
            let jump = simd_length(delta)
            if jump > maxDelta { delta *= maxDelta / jump }

            target = dragStartPosition + delta
        } else {
            let dx = hand.pinchPoint.x - dragStartPoint.x
            let dy = hand.pinchPoint.y - dragStartPoint.y
            let metersPerPoint = 1 / dragPointsPerMeter
            let lateral = dragRight * Float(dx) * Float(metersPerPoint)
                + dragUp * Float(-dy) * Float(metersPerPoint)
            target = dragStartPosition + lateral
        }

        let toTarget = target - dragStartCamera
        let distance = simd_length(toTarget)
        if distance > Float(Config.maxWindowDistance) {
            target = dragStartCamera + toTarget * (Float(Config.maxWindowDistance) / distance)
        } else if distance < Float(Config.minWindowDistance) {
            target = dragStartCamera + Self.normalized(toTarget, fallback: simd_float3(0, 0, -1))
                * Float(Config.minWindowDistance)
        }

        host.setPosition(window, dragFilter.filter(target), force: true)
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

            if bestDistance <= 0.035, touchLatched[hand.key] != true {
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
