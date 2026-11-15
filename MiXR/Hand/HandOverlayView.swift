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
    /// Esqueleto: líneas entre articulaciones y un punto en cada una.
    private let boneLayer = CAShapeLayer()
    private let jointLayer = CAShapeLayer()

    /// Largo del rayito (pt). Bien largo, como un puntero de verdad.
    static let rayLength: CGFloat = 190
    /// El esqueleto se puede apagar desde el tile "Manos".
    var showsSkeleton = true
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

        boneLayer.fillColor = UIColor.clear.cgColor
        boneLayer.strokeColor = UIColor.white.withAlphaComponent(0.78).cgColor
        boneLayer.lineWidth = 2.5
        boneLayer.lineCap = .round
        boneLayer.lineJoin = .round

        jointLayer.fillColor = UIColor.white.withAlphaComponent(0.95).cgColor
        jointLayer.strokeColor = UIColor.black.withAlphaComponent(0.35).cgColor
        jointLayer.lineWidth = 1

        for shape in [palmButtonLayer, dotLayer, pointerLayer, grabDotLayer, boneLayer, jointLayer] {
            layer.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for shape in [palmButtonLayer, dotLayer, pointerLayer, grabDotLayer, boneLayer, jointLayer] {
            shape.frame = bounds
        }
    }

    /// Aro de puntería (modo control / hover sobre un botón).
    func setPointer(_ point: CGPoint?) {
        pointerVisible = (point != nil)
    }
    /// Dibuja el esqueleto de cada mano: una línea por hueso y un punto en cada
    /// articulación (Vision entrega 21 por mano).
    private func drawSkeleton(_ poses: [HandPose]) {
        guard showsSkeleton else {
            boneLayer.path = nil
            jointLayer.path = nil
            return
        }

        let bones = UIBezierPath()
        let joints = UIBezierPath()

        for pose in poses {
            for chain in HandTracker.connections {
                var previous: CGPoint?
                for name in chain {
                    guard let point = pose.joints[name] else { previous = nil; continue }
                    if let previous {
                        bones.move(to: previous)
                        bones.addLine(to: point)
                    }
                    previous = point
                }
            }
            for (_, point) in pose.joints {
                joints.append(UIBezierPath(ovalIn: CGRect(x: point.x - 3,
                                                          y: point.y - 3,
                                                          width: 6, height: 6)))
            }
        }

        boneLayer.path = bones.cgPath
        jointLayer.path = joints.cgPath
    }

    func render(poses: [HandPose]) {
        dotLayer.path = nil

        // Esqueleto de precisión: líneas y puntos exactamente en las
        // articulaciones que entrega Vision (nudillos y yemas).
        drawSkeleton(poses)

        // Rayito largo desde el dedo con un punto en la punta.
        if pointerVisible, let pose = poses.first,
           let tip = pose.joints[.indexTip] {
            let base = pose.joints[.indexMCP] ?? pose.joints[.wrist] ?? tip
            let dx = tip.x - base.x
            let dy = tip.y - base.y
            let length = max(hypot(dx, dy), 1)
            let end = CGPoint(x: tip.x + dx / length * Self.rayLength,
                              y: tip.y + dy / length * Self.rayLength)

            let ray = UIBezierPath()
            ray.move(to: base)
            ray.addLine(to: end)
            ray.append(UIBezierPath(ovalIn: CGRect(x: end.x - 6, y: end.y - 6,
                                                    width: 12, height: 12)))
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
