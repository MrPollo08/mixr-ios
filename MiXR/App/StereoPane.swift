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
    func layoutScene(containerSize: CGSize, eyeShift: CGFloat) {
        guard containerSize.width > 1, containerSize.height > 1 else { return }

        let half = CGSize(width: containerSize.width / 2, height: containerSize.height / 2)
        stage.bounds = CGRect(origin: .zero, size: half)
        stage.center = CGPoint(x: bounds.midX, y: bounds.midY)
        stage.transform = CGAffineTransform(translationX: eyeShift, y: 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        background.frame = CGRect(origin: .zero, size: half)

        host.bounds = CGRect(origin: .zero, size: containerSize)
        host.center = CGPoint(x: half.width / 2, y: half.height / 2)
        host.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)

        overlay.bounds = CGRect(origin: .zero, size: containerSize)
        overlay.center = CGPoint(x: half.width / 2, y: half.height / 2)
        overlay.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)

        CATransaction.commit()
    }

    func render(poses: [HandPose]) {
        overlay.render(poses: poses)
    }
}
