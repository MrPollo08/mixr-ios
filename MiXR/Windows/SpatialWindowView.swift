import UIKit

/// Aspecto visual de una ventana espacial: tarjeta redondeada con cristal,
/// cabecera con título y contenido dentro.
///
/// El tamaño base es fijo (320 pt de ancho); el tamaño "real" se aplica con
/// `transform`, así todo el contenido escala junto como un cartel en el aire.
final class SpatialWindowView: UIView {

    static let baseWidth: CGFloat = 320
    static let headerHeight: CGFloat = 38

    var onClose: (() -> Void)?
    var onEditLink: (() -> Void)?
    var onTap: (() -> Void)?
    var onPan: ((UIPanGestureRecognizer) -> Void)?
    var onPinch: ((UIPinchGestureRecognizer) -> Void)?

    private var bodyAspect: CGFloat
    private let showsLinkButton: Bool
    private let showsCloseButton: Bool
    private let chromeless: Bool

    private let card = UIView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let header = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let linkButton = UIButton(type: .system)
    private let contentContainer = UIView()

    private(set) var content: UIView?

    var baseSize: CGSize {
        CGSize(width: Self.baseWidth,
               height: Self.baseWidth / bodyAspect + Self.headerHeight)
    }

    init(title: String, bodyAspect: CGFloat, showsLinkButton: Bool, showsCloseButton: Bool = true, chromeless: Bool = false) {
        self.bodyAspect = bodyAspect
        self.showsLinkButton = showsLinkButton
        self.showsCloseButton = showsCloseButton
        self.chromeless = chromeless
        super.init(frame: CGRect(x: 0, y: 0,
                                 width: Self.baseWidth,
                                 height: Self.baseWidth / bodyAspect + Self.headerHeight))
        build(title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    // MARK: - Construcción

    private func build(title: String) {
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false

        if chromeless {
            contentContainer.frame = bounds
            contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentContainer.backgroundColor = .clear
            addSubview(contentContainer)
            return
        }

        card.frame = bounds
        card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        card.clipsToBounds = true
        addSubview(card)

        blur.frame = card.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(blur)

        contentContainer.frame = CGRect(x: 0, y: Self.headerHeight,
                                        width: bounds.width,
                                        height: max(0, bounds.height - Self.headerHeight))
        contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.backgroundColor = .black
        contentContainer.clipsToBounds = true
        card.addSubview(contentContainer)

        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        header.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        header.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        card.addSubview(header)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        header.addSubview(titleLabel)

        style(button: closeButton, symbol: "xmark")
        style(button: linkButton, symbol: "link")
        linkButton.isHidden = !showsLinkButton
        closeButton.isHidden = !showsCloseButton
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        linkButton.addTarget(self, action: #selector(linkTapped), for: .touchUpInside)
        header.addSubview(closeButton)
        header.addSubview(linkButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panGesture(_:)))
        pan.cancelsTouchesInView = false
        header.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchGesture(_:)))
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapGesture))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    private func style(button: UIButton, symbol: String) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
        button.tintColor = UIColor.white.withAlphaComponent(0.88)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        button.layer.cornerRadius = 15
    }

    // MARK: - Contenido

    /// Resalta la ventana cuando la mano la agarra.
    func setGrabbed(_ grabbed: Bool) {
        card.layer.borderColor = grabbed
            ? UIColor(red: 0.42, green: 0.86, blue: 1.0, alpha: 0.95).cgColor
            : UIColor.white.withAlphaComponent(0.16).cgColor
        card.layer.borderWidth = grabbed ? 2.5 : 1
    }

    func setContent(_ view: UIView) {
        content?.removeFromSuperview()
        content = view
        view.frame = contentContainer.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.addSubview(view)
    }

    /// Ajusta la proporción del contenido (por ejemplo al tamaño real del
    /// stream del PC, que no siempre es 16:9).
    func setAspect(_ aspect: CGFloat) {
        guard aspect > 0.2, abs(aspect - bodyAspect) > 0.01 else { return }
        bodyAspect = aspect
        setNeedsLayout()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        card.frame = bounds
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        contentContainer.frame = CGRect(x: 0, y: Self.headerHeight,
                                        width: bounds.width,
                                        height: max(0, bounds.height - Self.headerHeight))

        let buttonSize: CGFloat = 30
        let buttonY = (Self.headerHeight - buttonSize) / 2
        closeButton.frame = CGRect(x: bounds.width - buttonSize - 8, y: buttonY,
                                   width: buttonSize, height: buttonSize)
        linkButton.frame = CGRect(x: closeButton.frame.minX - buttonSize - 4, y: buttonY,
                                  width: buttonSize, height: buttonSize)
        titleLabel.frame = CGRect(x: 14, y: 0,
                                  width: max(0, linkButton.frame.minX - 20),
                                  height: Self.headerHeight)
    }

    // MARK: - Acciones

    @objc private func closeTapped() { onClose?() }
    @objc private func linkTapped() { onEditLink?() }
    @objc private func tapGesture() { onTap?() }
    @objc private func panGesture(_ gesture: UIPanGestureRecognizer) { onPan?(gesture) }
    @objc private func pinchGesture(_ gesture: UIPinchGestureRecognizer) { onPinch?(gesture) }
}
