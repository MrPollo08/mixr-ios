import UIKit

/// Viñeta suave sobre el passthrough.
///
/// Oscurece los bordes del cuadro de cámara: el centro gana protagonismo y el mundo
/// se lee con más profundidad (el ojo interpreta que hay un espacio, no una foto plana).
final class VignetteView: UIView {

    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    /// Qué tan oscuros quedan los bordes (0 = nada, 1 = negro).
    var strength: CGFloat = 0.55 {
        didSet { applyColors() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false

        gradient.type = .radial
        gradient.locations = [0.0, 0.55, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.05, y: 1.05)
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    private func applyColors() {
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(strength).cgColor
        ]
    }
}
