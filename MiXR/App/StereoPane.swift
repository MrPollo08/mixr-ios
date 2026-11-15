import UIKit

/// Una mitad de la pantalla, para un ojo.
///
/// Cada ojo ve un **marco cuadrado redondeado** (como el visor de PC), con la
/// escena recortada adentro: nada (ni el menú) puede salirse del marco.
final class StereoPane: UIView {

    let background = CameraSampleView()
    let host = WindowHostView()
    let overlay = HandOverlayView()

    private let stage = UIView()
    private let vignette = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        stage.backgroundColor = .black
        stage.clipsToBounds = true
        addSubview(stage)

        stage.addSubview(background)
        stage.addSubview(host)
        stage.addSubview(overlay)

        // Viñeta: oscurece los bordes, como la lente del visor.
        vignette.type = .radial
        vignette.colors = [
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor
        ]
        vignette.locations = [0.0, 0.62, 1.0]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.05, y: 1.05)
        stage.layer.addSublayer(vignette)

        background.isUserInteractionEnabled = false
        overlay.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    /// Arma el marco cuadrado y encaja la escena adentro (recortando, no
    /// deformando), así el mundo se ve natural y las ventanas quedan alineadas.
    func layoutScene(containerSize: CGSize, scale: CGFloat, eyeShift: CGFloat, verticalOffset: CGFloat) {
        guard containerSize.width > 10, containerSize.height > 10,
              bounds.width > 10, bounds.height > 10 else { return }

        let side = min(bounds.width * 0.97, bounds.height * scale * 1.9)
        guard side > 20 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        stage.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        stage.center = CGPoint(x: bounds.midX + eyeShift, y: bounds.midY + verticalOffset)
        stage.layer.cornerRadius = side * 0.10
        stage.layer.cornerCurve = .continuous

        vignette.frame = CGRect(x: 0, y: 0, width: side, height: side)

        // Recorte "aspect fill" dentro del cuadrado.
        let fill = side / min(containerSize.width, containerSize.height)
        let scaled = CGSize(width: containerSize.width * fill,
                            height: containerSize.height * fill)

        background.frame = CGRect(x: (side - scaled.width) / 2,
                                  y: (side - scaled.height) / 2,
                                  width: scaled.width,
                                  height: scaled.height)

        host.bounds = CGRect(origin: .zero, size: containerSize)
        host.center = CGPoint(x: side / 2, y: side / 2)
        host.transform = CGAffineTransform(scaleX: fill, y: fill)

        overlay.bounds = CGRect(origin: .zero, size: containerSize)
        overlay.center = CGPoint(x: side / 2, y: side / 2)
        overlay.transform = CGAffineTransform(scaleX: fill, y: fill)

        CATransaction.commit()
    }

    func render(poses: [HandPose]) {
        overlay.render(poses: poses)
    }
}
