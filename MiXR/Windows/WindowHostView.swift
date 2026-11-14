import UIKit
import simd

/// Contiene las ventanas flotantes y las proyecta al espacio real.
///
/// Todo el cálculo pasa por `CameraPose`, así funciona igual con ARKit (6DoF)
/// o con la cámara gran angular (3DoF).
final class WindowHostView: UIView {

    weak var session: XRSession?
    var onCountChanged: ((Int) -> Void)?

    private(set) var windows: [SpatialWindow] = []
    private(set) var lastPose: CameraPose?

    private var pinchStartWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    // MARK: - Alta y baja

    @discardableResult
    func add(kind: WindowKind, position: simd_float3, physicalWidth: CGFloat) -> SpatialWindow {
        let view = SpatialWindowView(title: kind.title,
                                     bodyAspect: kind.aspect,
                                     showsLinkButton: kind.showsLinkButton)
        view.isHidden = true

        let window = SpatialWindow(kind: kind,
                                   position: position,
                                   physicalWidth: physicalWidth,
                                   view: view)

        let content = kind.makeContent()
        view.setContent(content)

        if let stream = content as? StreamContentView {
            stream.onVideoSize = { [weak self, weak window] size in
                guard let self, let window, size.height > 0 else { return }
                window.view.setAspect(size.width / size.height)
                self.layoutWindow(window)
            }
            stream.onRemoteHost = { [weak self] host in
                self?.session?.pcConnected(host: host)
            }
        }

        view.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.remove(window)
        }
        view.onEditLink = { [weak self, weak window] in
            guard let self, let window else { return }
            self.session?.promptForURL(title: "Cambiar enlace",
                                       message: "URL del video o de la página.",
                                       current: window.currentURL) { url in
                window.updateURL(url)
            }
        }
        view.onTap = { [weak self, weak window] in
            guard let self, let window else { return }
            self.bringToFront(window)
        }
        view.onPan = { [weak self, weak window] gesture in
            guard let self, let window else { return }
            self.handlePan(gesture, window: window)
        }
        view.onPinch = { [weak self, weak window] gesture in
            guard let self, let window else { return }
            self.handlePinch(gesture, window: window)
        }

        addSubview(view)
        windows.append(window)
        layoutWindow(window)
        onCountChanged?(windows.count)

        return window
    }

    func remove(_ window: SpatialWindow) {
        window.view.layer.removeAllAnimations()
        window.view.removeFromSuperview()
        windows.removeAll { $0 === window }
        onCountChanged?(windows.count)
    }

    func removeAll() {
        for window in windows {
            window.view.removeFromSuperview()
        }
        windows.removeAll()
        onCountChanged?(windows.count)
    }

    func bringToFront(_ window: SpatialWindow) {
        if let index = windows.firstIndex(where: { $0 === window }) {
            windows.remove(at: index)
            windows.append(window)
        }
        bringSubviewToFront(window.view)
    }

    /// Resalta la ventana agarrada por la mano.
    func setGrabbed(_ window: SpatialWindow?, grabbed: Bool) {
        window?.view.setGrabbed(grabbed)
    }

    /// Zona de la ventana que agarró la mano.
    enum GrabZone {
        case body
        case leftEdge
        case rightEdge
    }

    /// Los costados son "agarraderas" para estirar la ventana.
    func grabZone(for window: SpatialWindow, at point: CGPoint) -> GrabZone {
        let frame = window.view.frame
        guard frame.width > 8 else { return .body }
        let grip = min(max(frame.width * 0.15, 20), 52)
        if point.x <= frame.minX + grip { return .leftEdge }
        if point.x >= frame.maxX - grip { return .rightEdge }
        return .body
    }

    func center(of window: SpatialWindow) -> CGPoint {
        window.view.center
    }

    func setPosition(_ window: SpatialWindow, _ position: simd_float3) {
        window.position = position
        layoutWindow(window)
    }

    // MARK: - Proyección mundo → pantalla

    func layout(pose: CameraPose) {
        lastPose = pose
        for window in windows {
            layoutWindow(window)
        }
    }

    private func layoutWindow(_ window: SpatialWindow) {
        guard let pose = lastPose, let projection = pose.project(window.position) else {
            window.view.isHidden = true
            return
        }

        window.pointsPerMeter = projection.pointsPerMeter
        window.view.isHidden = false
        window.view.bounds = CGRect(origin: .zero, size: window.view.baseSize)
        window.view.center = projection.center

        let targetWidth = window.physicalWidth * projection.pointsPerMeter
        let scale = targetWidth / window.view.baseSize.width
        window.view.transform = CGAffineTransform(scaleX: scale, y: scale)

        // Se atenúa un poco con la distancia (efecto de profundidad).
        let fade = CGFloat(1.35 - projection.depth * 0.09)
        window.view.alpha = min(1, max(0.35, fade))
    }

    // MARK: - Interacción con el dedo (respaldo del tracking de manos)

    private func handlePan(_ gesture: UIPanGestureRecognizer, window: SpatialWindow) {
        guard let pose = lastPose else { return }
        switch gesture.state {
        case .began:
            bringToFront(window)
            setGrabbed(window, grabbed: true)
        case .changed:
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            move(window, dx: delta.x, dy: delta.y, pose: pose)
        default:
            setGrabbed(window, grabbed: false)
        }
    }

    private func handlePinch(_ gesture: UIPinchGestureRecognizer, window: SpatialWindow) {
        switch gesture.state {
        case .began:
            pinchStartWidth = window.physicalWidth
        case .changed:
            guard pinchStartWidth > 0 else { return }
            let width = pinchStartWidth * gesture.scale
            setWidth(window, meters: min(max(width, Config.minWindowWidth), Config.maxWindowWidth))
        default:
            pinchStartWidth = 0
        }
    }

    // MARK: - Movimiento

    /// Convierte un desplazamiento en puntos de pantalla a metros del mundo.
    func move(_ window: SpatialWindow, dx: CGFloat, dy: CGFloat, pose: CameraPose) {
        guard window.pointsPerMeter > 1, abs(dx) + abs(dy) > 0.01 else { return }

        let transform = pose.transform
        let right = simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let metersPerPoint = 1 / Float(window.pointsPerMeter)

        window.position += right * Float(dx) * metersPerPoint
        window.position += up * Float(-dy) * metersPerPoint
        layoutWindow(window)
    }

    func setWidth(_ window: SpatialWindow, meters: CGFloat) {
        guard abs(window.physicalWidth - meters) > 0.002 else { return }
        window.physicalWidth = meters
        layoutWindow(window)
    }

    // MARK: - Hit testing

    func window(at point: CGPoint) -> SpatialWindow? {
        for window in windows.reversed() where !window.view.isHidden {
            if window.view.frame.contains(point) { return window }
        }
        return nil
    }
}
