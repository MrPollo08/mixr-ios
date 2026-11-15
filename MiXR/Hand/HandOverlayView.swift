import UIKit
import Vision

/// Dibuja una **mano estilizada**: silueta oscura con borde blanco, más un
/// cursor (línea + punto) que sale del dedo índice.
///
/// Es la representación que se ve encima de las pantallas: no usa los píxeles
/// de la cámara, así que es liviana, no cuesta FPS y siempre se lee bien.
final class HandOverlayView: UIView {

    private let edgeLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let cursorLayer = CAShapeLayer()
    private let pointerLayer = CAShapeLayer()

    private static let palmNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        // Borde blanco: se dibuja un trazo más grueso debajo.
        edgeLayer.fillColor = UIColor.clear.cgColor
        edgeLayer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        edgeLayer.lineWidth = 7
        edgeLayer.lineCap = .round
        edgeLayer.lineJoin = .round

        // Relleno oscuro translúcido encima.
        fillLayer.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        fillLayer.strokeColor = UIColor.black.withAlphaComponent(0.55).cgColor
        fillLayer.lineWidth = 4.5
        fillLayer.lineCap = .round
        fillLayer.lineJoin = .round

        cursorLayer.fillColor = UIColor.white.cgColor
        cursorLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        cursorLayer.lineWidth = 2
        cursorLayer.lineCap = .round

        pointerLayer.fillColor = UIColor.white.withAlphaComponent(0.95).cgColor
        pointerLayer.strokeColor = UIColor(red: 0.42, green: 0.86, blue: 1.0, alpha: 0.95).cgColor
        pointerLayer.lineWidth = 2

        for shape in [edgeLayer, fillLayer, cursorLayer, pointerLayer] {
            layer.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for shape in [edgeLayer, fillLayer, cursorLayer, pointerLayer] {
            shape.frame = bounds
        }
    }

    /// Punto de puntería extra (modo control del PC).
    func setPointer(_ point: CGPoint?) {
        guard let point else {
            pointerLayer.path = nil
            return
        }
        let radius: CGFloat = 12
        let path = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                               width: radius * 2, height: radius * 2))
        pointerLayer.path = path.cgPath
    }

    func render(poses: [HandPose]) {
        let hand = UIBezierPath()
        let cursor = UIBezierPath()

        for pose in poses {
            for chain in HandTracker.connections {
                var started = false
                for name in chain {
                    guard let point = pose.joints[name] else { continue }
                    if started {
                        hand.addLine(to: point)
                    } else {
                        hand.move(to: point)
                        started = true
                    }
                }
            }

            let palmPoints = Self.palmNames.compactMap { pose.joints[$0] }
            if palmPoints.count >= 3 {
                var started = false
                for point in palmPoints {
                    if started {
                        hand.addLine(to: point)
                    } else {
                        hand.move(to: point)
                        started = true
                    }
                }
                hand.close()
            }
        }

        // Cursor: línea desde el dedo índice hacia donde apunta + punto.
        if let pose = poses.first,
           let tip = pose.joints[.indexTip] {
            let base = pose.joints[.indexMCP] ?? pose.joints[.wrist] ?? tip
            let dx = tip.x - base.x
            let dy = tip.y - base.y
            let length = max(hypot(dx, dy), 1)
            let end = CGPoint(x: tip.x + dx / length * 52, y: tip.y + dy / length * 52)

            cursor.move(to: tip)
            cursor.addLine(to: end)
            cursor.append(UIBezierPath(ovalIn: CGRect(x: end.x - 5, y: end.y - 5,
                                                      width: 10, height: 10)))
        }

        edgeLayer.path = hand.cgPath
        fillLayer.path = hand.cgPath
        cursorLayer.path = cursor.cgPath
    }
}
