import UIKit

/// Una mitad de la pantalla, para un ojo.
///
/// Muestra la **misma escena** que la vista normal pero escalada al 50%, con un
/// pequeño desplazamiento horizontal por ojo (paralaje). Es el modo para poner
/// el teléfono en las gafas VR: cada ojo ve su mitad.
final class StereoPane: UIView {

    let background = CameraSampleView()
    let host = WindowHostView()
    let overlay = HandOverlayView()

    private let stage = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        stage.backgroundColor = .clear
        addSubview(stage)
        stage.addSubview(background)
        stage.addSubview(host)
        stage.addSubview(overlay)

        background.isUserInteractionEnabled = false
        overlay.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    /// Arma la escena en coordenadas de pantalla completa y la escala a la mitad.
    func layoutScene(containerSize: CGSize, scale: CGFloat, eyeShift: CGFloat, verticalOffset: CGFloat) {
        guard containerSize.width > 1, containerSize.height > 1 else { return }

        let scaled = CGSize(width: containerSize.width * scale,
                            height: containerSize.height * scale)
        stage.bounds = CGRect(origin: .zero, size: scaled)
        stage.center = CGPoint(x: bounds.midX, y: bounds.midY + verticalOffset)
        stage.transform = CGAffineTransform(translationX: eyeShift, y: 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        background.frame = CGRect(origin: .zero, size: scaled)

        host.bounds = CGRect(origin: .zero, size: containerSize)
        host.center = CGPoint(x: scaled.width / 2, y: scaled.height / 2)
        host.transform = CGAffineTransform(scaleX: scale, y: scale)

        overlay.bounds = CGRect(origin: .zero, size: containerSize)
        overlay.center = CGPoint(x: scaled.width / 2, y: scaled.height / 2)
        overlay.transform = CGAffineTransform(scaleX: scale, y: scale)

        CATransaction.commit()
    }

    func render(poses: [HandPose]) {
        overlay.render(poses: poses)
    }
}
