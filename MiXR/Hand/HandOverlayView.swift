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
    /// Punto que marca la mano cuando agarra (va por encima de la ventana).
    private let grabDotLayer = CAShapeLayer()
    /// El puntero (rayito) sólo se dibuja cuando se apunta a algo.
    private var pointerVisible = false

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

        grabDotLayer.fillColor = UIColor.white.withAlphaComponent(0.95).cgColor
        grabDotLayer.strokeColor = UIColor(red: 0.42, green: 0.86, blue: 1.0, alpha: 0.95).cgColor
        grabDotLayer.lineWidth = 3

        for shape in [palmButtonLayer, dotLayer, pointerLayer, grabDotLayer] {
            layer.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for shape in [palmButtonLayer, dotLayer, pointerLayer, grabDotLayer] {
            shape.frame = bounds
        }
    }

    /// Aro de puntería (modo control / hover sobre un botón).
    func setPointer(_ point: CGPoint?) {
        pointerVisible = (point != nil)
    }
    func render(poses: [HandPose]) {
        // Sin gráficos sobre la mano: sólo el ☰ de la palma.
        dotLayer.path = nil

        // Rayito desde el dedo con un punto en la punta (para elegir apps).
        if pointerVisible, let pose = poses.first,
           let tip = pose.joints[.indexTip] {
            let base = pose.joints[.indexMCP] ?? pose.joints[.wrist] ?? tip
            let dx = tip.x - base.x
            let dy = tip.y - base.y
            let length = max(hypot(dx, dy), 1)
            let end = CGPoint(x: tip.x + dx / length * 46, y: tip.y + dy / length * 46)

            let ray = UIBezierPath()
            ray.move(to: base)
            ray.addLine(to: end)
            ray.append(UIBezierPath(ovalIn: CGRect(x: end.x - 5, y: end.y - 5,
                                                    width: 10, height: 10)))
            pointerLayer.path = ray.cgPath
            pointerLayer.fillColor = UIColor.white.cgColor
            pointerLayer.lineWidth = 2
            pointerLayer.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        } else {
            pointerLayer.path = nil
        }

        // Punto en la palma con el puño cerrado: así se ve que la ventana va
        // con la mano (el overlay está por encima de las ventanas).
        if let fist = poses.first(where: { $0.closedFist }) {
            let radius: CGFloat = 8
            let center = fist.palmCenter
            grabDotLayer.path = UIBezierPath(ovalIn: CGRect(x: center.x - radius,
                                                            y: center.y - radius,
                                                            width: radius * 2,
                                                            height: radius * 2)).cgPath
        } else {
            grabDotLayer.path = nil
        }

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
