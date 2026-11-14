import UIKit
import Vision

/// Dibuja el esqueleto de las manos encima de la cámara (solo lectura).
///
/// Se dibujan las 21 articulaciones con un halo, la palma translúcida y las
/// yemas más grandes, para que se lea igual que MediaPipe.
final class HandOverlayView: UIView {

    private let glowLayer = CAShapeLayer()
    private let boneLayer = CAShapeLayer()
    private let palmLayer = CAShapeLayer()
    private let jointLayer = CAShapeLayer()
    private let fingertipLayer = CAShapeLayer()
    private let pinchLayer = CAShapeLayer()
    private let pointerLayer = CAShapeLayer()

    private let accent = UIColor(red: 0.42, green: 0.86, blue: 1.0, alpha: 1)

    private static let palmChain: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP
    ]

    private static let fingertipNames: [VNHumanHandPoseObservation.JointName] = [
        .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        glowLayer.fillColor = UIColor.clear.cgColor
        glowLayer.strokeColor = accent.withAlphaComponent(0.22).cgColor
        glowLayer.lineWidth = 9
        glowLayer.lineCap = .round
        glowLayer.lineJoin = .round

        boneLayer.fillColor = UIColor.clear.cgColor
        boneLayer.strokeColor = accent.withAlphaComponent(0.95).cgColor
        boneLayer.lineWidth = 3
        boneLayer.lineCap = .round
        boneLayer.lineJoin = .round

        palmLayer.fillColor = accent.withAlphaComponent(0.16).cgColor
        palmLayer.strokeColor = accent.withAlphaComponent(0.35).cgColor
        palmLayer.lineWidth = 1

        jointLayer.fillColor = UIColor.white.withAlphaComponent(0.92).cgColor

        fingertipLayer.fillColor = UIColor(red: 1.0, green: 0.93, blue: 0.55, alpha: 1).cgColor

        pinchLayer.fillColor = UIColor.clear.cgColor
        pinchLayer.strokeColor = UIColor(red: 1.0, green: 0.72, blue: 0.2, alpha: 0.95).cgColor
        pinchLayer.lineWidth = 3

        pointerLayer.fillColor = UIColor.white.withAlphaComponent(0.95).cgColor
        pointerLayer.strokeColor = accent.cgColor
        pointerLayer.lineWidth = 2

        for shape in [glowLayer, boneLayer, palmLayer, jointLayer, fingertipLayer, pinchLayer, pointerLayer] {
            layer.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for shape in [glowLayer, boneLayer, palmLayer, jointLayer, fingertipLayer, pinchLayer, pointerLayer] {
            shape.frame = bounds
        }
    }

    /// Punto donde está apuntando la mano en modo control (nil = oculto).
    func setPointer(_ point: CGPoint?) {
        guard let point else {
            pointerLayer.path = nil
            return
        }
        let radius: CGFloat = 13
        let path = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                               width: radius * 2, height: radius * 2))
        path.move(to: CGPoint(x: point.x - radius - 6, y: point.y))
        path.addLine(to: CGPoint(x: point.x - radius + 2, y: point.y))
        path.move(to: CGPoint(x: point.x + radius - 2, y: point.y))
        path.addLine(to: CGPoint(x: point.x + radius + 6, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - radius - 6))
        path.addLine(to: CGPoint(x: point.x, y: point.y - radius + 2))
        path.move(to: CGPoint(x: point.x, y: point.y + radius - 2))
        path.addLine(to: CGPoint(x: point.x, y: point.y + radius + 6))
        pointerLayer.path = path.cgPath
    }

    func render(poses: [HandPose]) {
        let bones = UIBezierPath()
        let palms = UIBezierPath()
        let joints = UIBezierPath()
        let fingertips = UIBezierPath()
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

            let palmPoints = Self.palmChain.compactMap { pose.joints[$0] }
            if palmPoints.count >= 3 {
                var started = false
                for point in palmPoints {
                    if started {
                        palms.addLine(to: point)
                    } else {
                        palms.move(to: point)
                        started = true
                    }
                }
                palms.close()
            }

            for (name, point) in pose.joints {
                if Self.fingertipNames.contains(name) {
                    fingertips.append(UIBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4,
                                                                  width: 8, height: 8)))
                } else {
                    joints.append(UIBezierPath(ovalIn: CGRect(x: point.x - 2.6, y: point.y - 2.6,
                                                              width: 5.2, height: 5.2)))
                }
            }

            if pose.pinch > 0.55 {
                let radius = 12 + (1 - pose.pinch) * 18
                pinches.append(UIBezierPath(ovalIn: CGRect(x: pose.pinchPoint.x - radius,
                                                           y: pose.pinchPoint.y - radius,
                                                           width: radius * 2,
                                                           height: radius * 2)))
            }
        }

        glowLayer.path = bones.cgPath
        boneLayer.path = bones.cgPath
        palmLayer.path = palms.cgPath
        jointLayer.path = joints.cgPath
        fingertipLayer.path = fingertips.cgPath
        pinchLayer.path = pinches.cgPath
    }
}
