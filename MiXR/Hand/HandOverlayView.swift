import UIKit
import Vision

/// Overlay de la mano **sin esqueleto**: nada de líneas, nada de malla.
///
/// Sólo se dibuja:
///  - un punto sutil en la yema del índice (donde está el puntero),
///  - y el botón ☰ en el centro de la palma cuando la mano está abierta.
final class HandOverlayView: UIView {

    private let dotLayer = CAShapeLayer()
    private let palmButtonLayer = CAShapeLayer()
    private let pointerLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        dotLayer.fillColor = UIColor.white.withAlphaComponent(0.9).cgColor
        dotLayer.strokeColor = UIColor.black.withAlphaComponent(0.35).cgColor
        dotLayer.lineWidth = 1

        palmButtonLayer.fillColor = UIColor(white: 0.15, alpha: 0.65).cgColor
        palmButtonLayer.strokeColor = UIColor.white.withAlphaComponent(0.75).cgColor
        palmButtonLayer.lineWidth = 2

        pointerLayer.fillColor = UIColor.clear.cgColor
        pointerLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        pointerLayer.lineWidth = 2

        for shape in [palmButtonLayer, dotLayer, pointerLayer] {
            layer.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for shape in [palmButtonLayer, dotLayer, pointerLayer] {
            shape.frame = bounds
        }
    }

    /// Aro de puntería (modo control / hover sobre un botón).
    func setPointer(_ point: CGPoint?) {
        guard let point else {
            pointerLayer.path = nil
            return
        }
        let radius: CGFloat = 11
        pointerLayer.path = UIBezierPath(ovalIn: CGRect(x: point.x - radius,
                                                        y: point.y - radius,
                                                        width: radius * 2,
                                                        height: radius * 2)).cgPath
    }

    func render(poses: [HandPose]) {
        // Sin gráficos sobre la mano: sólo el ☰ de la palma.
        dotLayer.path = nil

        // ☰ en la palma, sólo con la mano abierta.
        if let open = poses.first(where: { $0.openPalm }),
           let wrist = open.joints[.wrist],
           let middle = open.joints[.middleMCP] {
            let center = CGPoint(x: (wrist.x + middle.x) / 2,
                                 y: (wrist.y + middle.y) / 2)
            let radius = max(22, min(34, hypot(wrist.x - middle.x, wrist.y - middle.y) * 0.85))

            let path = UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))

            let barWidth = radius * 0.9
            for offset in [-0.28, 0.0, 0.28] {
                let y = center.y + CGFloat(offset) * radius
                path.move(to: CGPoint(x: center.x - barWidth / 2, y: y))
                path.addLine(to: CGPoint(x: center.x + barWidth / 2, y: y))
            }
            palmButtonLayer.path = path.cgPath
        } else {
            palmButtonLayer.path = nil
        }
    }
}
