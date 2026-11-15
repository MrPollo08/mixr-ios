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
    /// Eje de visión al momento de agarrar y resto del vector de posición:
    /// así el empuje en profundidad no se mezcla con el movimiento lateral.
    private var startForward = simd_float3(0, 0, -1)
    private var startLateral = simd_float3.zero
    /// Distancia al agarrar: la ventana (la del mundo) y la mano (la del LiDAR).
    private var appliedDistance: CGFloat = 0
    private var startHandDepth: Float = 0
    /// Pose de la cámara al agarrar (para el arrastre con 6DoF).
    private var startPose: CameraPose?
    /// Última distancia LiDAR a la mano (la escribe `update`).
    private var latestHandDepth: Float?
    private var applied: CGSize = .zero
    private var lastPoint: CGPoint?
    private var lastSeenAt: CFTimeInterval = 0

    private var twoHandResize = false
    private var resizeSpan: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0

    private var latch: [String: Bool] = [:]
    /// Ventana cuya barra de agarre está iluminada.
    private var barWindow: SpatialWindow?
    /// Cuántos frames seguidos la mano viene cerrada (debounce del agarre).
    private var grabStreak: [String: Int] = [:]
    private let grabFrames = 3
    private let minConfidence: CGFloat = 0.55
    private var lastHoverAt: CFTimeInterval = 0
    private let grace: TimeInterval = 0.45

    var isDragging: Bool { grabbed != nil }
    /// Ventana que se está arrastrando (para el modo VR).
    var grabbedWindow: SpatialWindow? { grabbed }

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
        barWindow?.view.setGrabBar(near: false)
        barWindow = nil
    }

    func update(poses: [HandPose], host: WindowHostView, handDepth: Float? = nil) {
        guard let pose = host.lastPose else { return }
        let now = CACurrentMediaTime()
        latestHandDepth = handDepth

        // 1. Pinza por mano, con histéresis.
        var pinching: [HandPose] = []
        var activeKeys = Set<String>()
        var emptyRising: [CGPoint] = []

        for hand in poses {
            activeKeys.insert(hand.key)
            let wasPinching = latch[hand.key] ?? false
            let threshold: CGFloat = wasPinching ? 0.55 : 0.78
            // Agarrede directo: se agarra cerrando el puño, no con pinza.
            // Debounce: hace falta que el puño se sostenga varios frames.
            if hand.closedFist, hand.confidence >= minConfidence {
                grabStreak[hand.key, default: 0] += 1
            } else {
                grabStreak[hand.key] = 0
            }
            let stableGrab = (grabStreak[hand.key] ?? 0) >= grabFrames
            let isPinching = stableGrab && hand.closedFist && hand.confidence >= minConfidence
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

        let viewport = host.lastPose?.viewport ?? .zero
        let safe = CGRect(origin: .zero, size: viewport).insetBy(dx: viewport.width * 0.06,
                                                                 dy: viewport.height * 0.06)

        guard let window = grabbed else {
            // Zona muerta: no se reacciona cerca de los bordes.
            if safe.width > 1, pinching.contains(where: { !safe.contains(dragPoint($0)) }) {
                updateBarHighlight(nil)
                return
            }
            updateHover(poses: poses, host: host)
            updateBarHighlight(poses.first.flatMap { host.window(atBar: $0.palmCenter) })

            // La barra del costado manda: es el agarre de la ventana.
            if let first = pinching.first {
                let point = dragPoint(first)
                if let byBar = host.window(atBar: point) {
                    begin(window: byBar, with: first, host: host)
                } else if let target = host.window(at: point) ?? host.window(near: point, margin: 22) {
                    begin(window: target, with: first, host: host)
                }
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
        applied = total

        // ---- Profundidad (LiDAR): alejar / traer la ventana ----
        // La ventana se mueve en el eje de visión lo mismo que se mueve la mano
        // hacia adelante o hacia atrás. Suavizado + zona muerta: queda firme.
        if startHandDepth > 0.1, let handDepth, handDepth > 0.1 {
            let startDistance = CGFloat(startDepth)
            let push = CGFloat(startHandDepth) - CGFloat(handDepth)   // + = la acercó
            let target = startDistance - push * Config.windowDepthGain
            let clamped = min(max(target, Config.minWindowDistance), Config.maxWindowDistance)
            if abs(clamped - appliedDistance) > 0.015 {
                appliedDistance += (clamped - appliedDistance) * 0.20
            } else {
                appliedDistance = clamped
            }
        } else if startHandSize > 4 {
            // Sin LiDAR: se estima con el tamaño aparente de la mano (visión).
            let size = handSize(of: hand)
            if size > 4 {
                let ratio = min(max(CGFloat(startHandSize / size), 0.6), 1.7)
                let target = CGFloat(startDepth) * ratio
                appliedDistance += (target - appliedDistance) * 0.12
            }
        }

        // ---- Lateral con 6DoF ----
        // La dirección del dedo se lleva al mundo con la pose de la cámara al
        // agarrar: si girás la cabeza mientras arrastrás, la ventana NO se corre
        // sola (el mundo no se mueve: la mano sí).
        let startOffset = rayOffset(startPoint, pose: startPose ?? pose)
        let nowOffset = rayOffset(point, pose: pose)
        let lateral = (nowOffset - startOffset) * Float(appliedDistance)

        let position = startCamera
            + startForward * Float(appliedDistance)
            + startLateral
            + lateral
        host.setPosition(window, position)
    }

    /// Dirección del rayo de cámara para un punto de pantalla, en coordenadas de
    /// mundo y **sin normalizar** (así el desplazamiento es lineal con los pt).
    private func rayOffset(_ point: CGPoint, pose: CameraPose) -> simd_float3 {
        let width = max(pose.viewport.width, 1)
        let height = max(pose.viewport.height, 1)
        let focalX = max(pose.focalX, 1)
        let focalY = max(pose.focalY, 1)

        let x = Float((point.x - width / 2) / focalX)
        let y = Float(-(point.y - height / 2) / focalY)

        let right = pose.transform.columns.0
        let up = pose.transform.columns.1
        return simd_float3(right.x, right.y, right.z) * x
            + simd_float3(up.x, up.y, up.z) * y
    }

    // MARK: - Agarre

    private func begin(window: SpatialWindow, with hand: HandPose, host: WindowHostView) {
        let point = dragPoint(hand)

        // El menú no se puede cerrar, pero sí mover: si la pinza cae en un tile,
        // se aprieta; si cae en el panel, se arrastra como cualquier ventana.
        // Los botones se activan con el cursor (dwell), no con el agarre.

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

            let column = current.transform.columns.2
            startForward = -simd_float3(column.x, column.y, column.z)
            let distance = Float(projection.depth)
            startLateral = startPosition - startCamera - startForward * distance
            appliedDistance = CGFloat(projection.depth)
        } else {
            startDepth = 0
            startForward = simd_float3(0, 0, -1)
            startLateral = .zero
            appliedDistance = 1
        }
        startHandDepth = latestHandDepth ?? 0
        startPose = host.lastPose
        depthRatio = 1
        twoHandResize = false
        lastSeenAt = CACurrentMediaTime()

        host.bringToFront(window)
        host.setGrabbed(window, grabbed: true)
    }

    private func end(host: WindowHostView) {
        if let window = grabbed {
            host.setGrabbed(window, grabbed: false)
            window.view.setGrabBar(near: false)
        }
        grabbed = nil
        dragKey = nil
        twoHandResize = false
        depthRatio = 1
        barWindow = nil
    }

    /// Enciende la barra de la ventana que está bajo la mano.
    private func updateBarHighlight(_ window: SpatialWindow?) {
        guard barWindow !== window else { return }
        barWindow?.view.setGrabBar(near: false)
        window?.view.setGrabBar(near: true)
        barWindow = window
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
        hand.palmCenter
    }

    /// Tamaño aparente de la mano en pantalla (crece cuando se acerca).
    private func handSize(of hand: HandPose) -> CGFloat {
        guard let wrist = hand.joints[.wrist], let middle = hand.joints[.middleMCP] else { return 0 }
        return hypot(wrist.x - middle.x, wrist.y - middle.y)
    }
}
