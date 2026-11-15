import CoreGraphics
import Foundation
import QuartzCore
import simd

/// Los únicos dos gestos del monitor:
///
/// - **Pinza cerca del borde** de la ventana: la pegás y la movés con la mano.
/// - **Dos pinzas** (una en cada mano): agrandar / achicar.
///
/// No hay agarre por puño, ni barra, ni profundidad: sólo pinza.
final class GestureEngine {

    private var grabbed: SpatialWindow?
    private var startPoint: CGPoint = .zero
    private var startPosition: simd_float3 = .zero
    private var startWidth: CGFloat = 0
    private var startSpan: CGFloat = 0
    private var startPose: CameraPose?
    private var resizing = false
    private var lastSeenAt: CFTimeInterval = 0
    private let grace: TimeInterval = 0.40

    var isDragging: Bool { grabbed != nil }

    func reset() {
        grabbed = nil
        resizing = false
        startPose = nil
    }

    func update(poses: [HandPose], host: WindowHostView, pose: CameraPose) {
        let now = CACurrentMediaTime()
        let pinching = poses.filter { $0.pinch >= 0.55 }

        guard let window = grabbed else {
            guard let first = pinching.first,
                  let target = host.window(nearBorder: first.pinchPoint) else { return }
            begin(window: target, with: first, host: host, pose: pose)
            return
        }

        // ---- Dos manos: escala ----
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

        // ---- Una mano: mover (con un poco de gracia si Vision la pierde) ----
        guard let hand = pinching.first else {
            if now - lastSeenAt < grace { return }
            reset()
            return
        }
        lastSeenAt = now

        if resizing {
            // Volvió a una sola mano: reenganchar sin salto.
            resizing = false
            begin(window: window, with: hand, host: host, pose: pose)
            return
        }

        move(window, to: hand.pinchPoint, pose: pose, host: host)
    }

    // MARK: - Piezas

    private func begin(window: SpatialWindow,
                       with hand: HandPose,
                       host: WindowHostView,
                       pose: CameraPose) {
        grabbed = window
        startPoint = hand.pinchPoint
        startPosition = window.position
        startPose = pose
        resizing = false
        lastSeenAt = CACurrentMediaTime()
        host.bringToFront(window)
        host.setGrabbed(window, grabbed: true)
    }

    private func move(_ window: SpatialWindow,
                      to point: CGPoint,
                      pose: CameraPose,
                      host: WindowHostView) {
        // 1:1 en pantalla: el desplazamiento del dedo se pasa a metros con la
        // escala del panel (así no salta si cambia la profundidad).
        let pointsPerMeter = window.pointsPerMeter > 1 ? window.pointsPerMeter : 600
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y

        let transform = pose.transform
        let right = simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let lateral = right * Float(dx / pointsPerMeter)
            + up * Float(-dy / pointsPerMeter)

        host.setPosition(window, startPosition + lateral, force: true)
    }
}
