import CoreGraphics
import Foundation
import QuartzCore
import simd

/// Motor de interacción espacial 3D (Pinza + Profundidad LiDAR + Dwell en Menú Overlay):
///
/// - **Pinza en el borde o barra lateral**: agarra la ventana y la traslada en 3D
///   (lateral X/Y + profundidad real Z medida por el sensor LiDAR).
/// - **Dos pinzas** (una en cada mano): escala el tamaño físico en metros.
/// - **Dedo índice sobre menú flotante (Overlay UI)**: acumula dwell o clic por pinza.
final class GestureEngine {

    private var grabbed: SpatialWindow?
    private var startPoint: CGPoint = .zero
    private var startPosition: simd_float3 = .zero
    private var startCameraPosition: simd_float3 = .zero
    private var startForward: simd_float3 = simd_float3(0, 0, -1)
    private var startLateralOffset: simd_float3 = .zero
    private var startWindowDepth: Float = 1.4
    private var appliedWindowDepth: Float = 1.4
    private var startHandDepth: Float = 0.42
    private var startWidth: CGFloat = 0
    private var startSpan: CGFloat = 0
    private var resizing = false
    private var lastSeenAt: CFTimeInterval = 0
    private var lastUpdateAt: CFTimeInterval = 0
    private let grace: TimeInterval = 0.40

    var isDragging: Bool { grabbed != nil }

    func reset() {
        if let grabbed {
            grabbed.view.setGrabbed(false)
            grabbed.view.setGrabBar(near: false)
        }
        grabbed = nil
        resizing = false
    }

    func update(poses: [HandPose], host: WindowHostView, pose: CameraPose) {
        let now = CACurrentMediaTime()
        let dt = lastUpdateAt > 0 ? CGFloat(min(max(now - lastUpdateAt, 1.0 / 120.0), 0.1)) : CGFloat(1.0 / 60.0)
        lastUpdateAt = now

        let pinching = poses.filter { $0.pinch >= 0.55 }

        guard let window = grabbed else {
            updateMenuHover(poses: poses, pinching: pinching, host: host, dt: dt)

            // Iluminar barra lateral cuando la mano se acerca
            for w in host.windows {
                let nearBar = poses.first.map { host.grabBarRect(for: w).contains($0.pinchPoint) } ?? false
                w.view.setGrabBar(near: nearBar)
            }

            guard let first = pinching.first else { return }
            if let byBar = host.window(atBar: first.pinchPoint) {
                begin(window: byBar, with: first, host: host, pose: pose)
            } else if let byBorder = host.window(nearBorder: first.pinchPoint) {
                begin(window: byBorder, with: first, host: host, pose: pose)
            }
            return
        }

        // ---- Dos manos: escalar ancho físico en metros ----
        if pinching.count >= 2 {
            let a = pinching[0].pinchPoint
            let b = pinching[1].pinchPoint
            let span = hypot(a.x - b.x, a.y - b.y)

            if !resizing {
                resizing = true
                startSpan = span
                startWidth = window.physicalWidth
            } else if startSpan > 8, span > 8 {
                let width = startWidth * (span / startSpan)
                host.setWidth(window,
                              meters: min(max(width, Config.minWindowWidth), Config.maxWindowWidth))
            }
            lastSeenAt = now
            return
        }

        // ---- Una mano: mover en 3D (X, Y + profundidad Z con LiDAR) ----
        guard let hand = pinching.first else {
            if now - lastSeenAt < grace { return }
            host.setGrabbed(window, grabbed: false)
            window.view.setGrabBar(near: false)
            reset()
            return
        }
        lastSeenAt = now

        if resizing {
            resizing = false
            begin(window: window, with: hand, host: host, pose: pose)
            return
        }

        move3D(window, with: hand, pose: pose, host: host)
    }

    // MARK: - Interacción con Menú Flotante (Overlay UI)

    private func updateMenuHover(poses: [HandPose],
                                 pinching: [HandPose],
                                 host: WindowHostView,
                                 dt: CGFloat) {
        let menuWindows = host.windows.filter { $0.pressAt != nil && !$0.view.isHidden }
        guard !menuWindows.isEmpty else { return }

        guard let hand = poses.first else {
            for menu in menuWindows { menu.hoverAt?(nil, dt) }
            return
        }

        let pointerPt = hand.joints[.indexTip] ?? hand.pinchPoint
        for menu in menuWindows {
            if menu.view.frame.insetBy(dx: -24, dy: -24).contains(pointerPt) {
                menu.hoverAt?(pointerPt, dt)
                if hand.pinch >= 0.65 {
                    _ = menu.pressAt?(pointerPt)
                }
            } else {
                menu.hoverAt?(nil, dt)
            }
        }
    }

    // MARK: - Arrastre 3D enriquecido con LiDAR

    private func begin(window: SpatialWindow,
                       with hand: HandPose,
                       host: WindowHostView,
                       pose: CameraPose) {
        grabbed = window
        startPoint = hand.pinchPoint
        startPosition = window.position
        startHandDepth = hand.depthMeters
        resizing = false
        lastSeenAt = CACurrentMediaTime()

        let cols = pose.transform.columns
        startCameraPosition = simd_float3(cols.3.x, cols.3.y, cols.3.z)
        startForward = -simd_float3(cols.2.x, cols.2.y, cols.2.z)

        if let proj = pose.project(window.position) {
            startWindowDepth = proj.depth
            appliedWindowDepth = proj.depth
            startLateralOffset = startPosition - startCameraPosition - startForward * proj.depth
        } else {
            let d = max(simd_distance(startPosition, startCameraPosition), 0.8)
            startWindowDepth = d
            appliedWindowDepth = d
            startLateralOffset = .zero
        }

        host.bringToFront(window)
        host.setGrabbed(window, grabbed: true)
    }

    private func move3D(_ window: SpatialWindow,
                        with hand: HandPose,
                        pose: CameraPose,
                        host: WindowHostView) {
        let pointsPerMeter = window.pointsPerMeter > 1 ? window.pointsPerMeter : 600
        let dx = hand.pinchPoint.x - startPoint.x
        let dy = hand.pinchPoint.y - startPoint.y

        let transform = pose.transform
        let right = simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let lateral = right * Float(dx / pointsPerMeter)
            + up * Float(-dy / pointsPerMeter)

        // Si el sensor LiDAR está midiendo la profundidad real de la mano, permitimos
        // acercar o alejar la ventana en el eje Z real al empujar/traer la mano.
        if hand.hasLiDAR, startHandDepth > 0.10, hand.depthMeters > 0.10 {
            let pushDelta = startHandDepth - hand.depthMeters // + = acercó la mano, - = alejó la mano
            if abs(pushDelta) > 0.022 {
                let targetDepth = startWindowDepth - pushDelta * Float(Config.windowDepthGain)
                let clamped = min(max(targetDepth, Float(Config.minWindowDistance)), Float(Config.maxWindowDistance))
                appliedWindowDepth += (clamped - appliedWindowDepth) * 0.18
            }
        }

        let depthShift = startForward * (appliedWindowDepth - startWindowDepth)
        let newPosition = startPosition + lateral + depthShift
        host.setPosition(window, newPosition, force: true)
    }
}
