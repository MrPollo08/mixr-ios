import CoreGraphics
import Foundation
import UIKit
import Vision

/// Convierte la mano en el mouse del PC: el dedo índice mueve el cursor y la
/// pinza hace clic, igual que un control remoto en el aire.
///
/// El mapeo es absoluto: el área visible de la cámara se corresponde con toda
/// la pantalla del PC, así se llega a cualquier esquina con un movimiento corto.
final class PointerController {

    let client = InputClient()

    private(set) var isEnabled = false
    private(set) var position: CGPoint?

    private var pressed = false
    private var lastMoveAt: CFTimeInterval = 0
    private var smoothed: CGPoint?

    /// Margen del área útil: 6% a cada lado (los bordes del cuadro son incómodos).
    private let margin: CGFloat = 0.06
    private let smoothing: CGFloat = 0.55

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            releaseIfNeeded()
            position = nil
            smoothed = nil
        }
    }

    @discardableResult
    func update(poses: [HandPose], viewport: CGSize) -> CGPoint? {
        guard isEnabled, viewport.width > 1, viewport.height > 1 else { return nil }

        guard let hand = chosen(from: poses) else {
            releaseIfNeeded()
            position = nil
            smoothed = nil
            return nil
        }

        // La yema del índice mueve el cursor.
        let tip = hand.joints[.indexTip] ?? hand.pinchPoint

        var nx = (tip.x / viewport.width - margin) / (1 - margin * 2)
        var ny = (tip.y / viewport.height - margin) / (1 - margin * 2)
        nx = min(max(nx, 0), 1)
        ny = min(max(ny, 0), 1)

        if let previous = smoothed {
            nx = previous.x + (nx - previous.x) * smoothing
            ny = previous.y + (ny - previous.y) * smoothing
        }
        smoothed = CGPoint(x: nx, y: ny)
        position = tip

        let now = CACurrentMediaTime()
        if now - lastMoveAt >= 1.0 / 60.0 {
            lastMoveAt = now
            client.sendMove(x: nx, y: ny)
        }

        // Pinza = botón izquierdo (con histéresis para que no repique).
        if hand.pinch > 0.72, !pressed {
            pressed = true
            client.sendButton(down: true)
        } else if hand.pinch < 0.50, pressed {
            pressed = false
            client.sendButton(down: false)
        }

        return tip
    }

    /// Si hay dos manos, manda la que está pellizcando (es la que va a hacer clic).
    private func chosen(from poses: [HandPose]) -> HandPose? {
        if let pinching = poses.first(where: { $0.pinch > 0.6 }) { return pinching }
        return poses.first
    }

    private func releaseIfNeeded() {
        guard pressed else { return }
        pressed = false
        client.sendButton(down: false)
    }
}
