import UIKit
import Vision

/// Dibuja el esqueleto de las manos encima de la cámara (solo lectura).
final class HandOverlayView: UIView {

    private let boneLayer = CAShapeLayer()
    private let jointLayer = CAShapeLayer()
    private let pinchLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        boneLayer.fillColor = UIColor.clear.cgColor
        boneLayer.strokeColor = UIColor(red: 0.42, green: 0.86, blue: 1.0, alpha: 0.85).cgColor
        boneLayer.lineWidth = 3
        boneLayer.lineCap = .round
        boneLayer.lineJoin = .round

        jointLayer.fillColor = UIColor.white.withAlphaComponent(0.9).cgColor

        pinchLayer.fillColor = UIColor.clear.cgColor
        pinchLayer.strokeColor = UIColor(red: 1.0, green: 0.72, blue: 0.2, alpha: 0.95).cgColor
        pinchLayer.lineWidth = 3

        for shape in [boneLayer, jointLayer, pinchLayer] {
            layer.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        boneLayer.frame = bounds
        jointLayer.frame = bounds
        pinchLayer.frame = bounds
    }

    func render(poses: [HandPose]) {
        let bones = UIBezierPath()
        let joints = UIBezierPath()
        let pinches = UIBezierPath()

        for pose in poses {
            for chain in HandTracker.connections {
                var started = false
                for name in chain {
                    guard let point = pose.joints[name] else { continue }
                    if started {
                        bones.addLine(to: point)
                    } else {
                        bones.move(to: point)
                        started = true
                    }
                }
            }

            for point in pose.joints.values {
                joints.append(UIBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3,
                                                          width: 6, height: 6)))
            }

            if pose.pinch > 0.55 {
                let radius = 12 + (1 - pose.pinch) * 18
                pinches.append(UIBezierPath(ovalIn: CGRect(x: pose.pinchPoint.x - radius,
                                                           y: pose.pinchPoint.y - radius,
                                                           width: radius * 2,
                                                           height: radius * 2)))
            }
        }

        boneLayer.path = bones.cgPath
        jointLayer.path = joints.cgPath
        pinchLayer.path = pinches.cgPath
    }
}
