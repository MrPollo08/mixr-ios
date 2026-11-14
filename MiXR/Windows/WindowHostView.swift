import ARKit
import UIKit
import simd

/// Contiene las ventanas flotantes y las proyecta al espacio real:
/// cada frame ARKit dice dónde está la cámara, así las ventanas se quedan
/// "pegadas" al mundo mientras movés el teléfono.
final class WindowHostView: UIView {

    weak var session: XRSession?
    var onCountChanged: ((Int) -> Void)?

    private(set) var windows: [SpatialWindow] = []
    private(set) var lastCamera: ARCamera?

    private var lastViewport: CGSize = .zero
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
                                     showsLinkButton: true)
        view.isHidden = true

        let window = SpatialWindow(kind: kind,
                                   position: position,
                                   physicalWidth: physicalWidth,
                                   view: view)

        view.setContent(kind.makeContent())

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

    // MARK: - Proyección mundo → pantalla

    func layout(camera: ARCamera, viewportSize: CGSize) {
        lastCamera = camera
        lastViewport = viewportSize
        for window in windows {
            layoutWindow(window)
        }
    }

    private func layoutWindow(_ window: SpatialWindow) {
        guard let camera = lastCamera else {
            window.view.isHidden = true
            return
        }
        let viewport = lastViewport == .zero ? bounds.size : lastViewport
        guard viewport.width > 1, viewport.height > 1 else { return }

        // Profundidad = distancia de la ventana al plano de la cámara.
        let worldToCamera = simd_inverse(camera.transform)
        let inCamera = worldToCamera * simd_float4(window.position, 1)
        let depth = -inCamera.z

        guard depth > Config.minDepth, depth < Config.maxDepth else {
            window.view.isHidden = true
            return
        }

        // Puntos de pantalla por metro a esa profundidad (escala real).
        let pointsPerMeter = CGFloat(camera.projectionMatrix.columns.1.y)
            * viewport.height / 2 / CGFloat(depth)

        let projected = camera.projectPoint(window.position,
                                            orientation: .portrait,
                                            viewportSize: viewport)

        window.pointsPerMeter = pointsPerMeter
        window.view.isHidden = false
        window.view.bounds = CGRect(origin: .zero, size: window.view.baseSize)
        window.view.center = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))

        let targetWidth = window.physicalWidth * pointsPerMeter
        let scale = targetWidth / window.view.baseSize.width
        window.view.transform = CGAffineTransform(scaleX: scale, y: scale)
        window.view.alpha = min(1, max(0.35, 1.35 - depth * 0.09))
    }

    // MARK: - Interacción con el dedo (respaldo del tracking de manos)

    private func handlePan(_ gesture: UIPanGestureRecognizer, window: SpatialWindow) {
        guard let camera = lastCamera else { return }
        switch gesture.state {
        case .began:
            bringToFront(window)
        case .changed:
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            move(window, dx: delta.x, dy: delta.y, camera: camera)
        default:
            break
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
    func move(_ window: SpatialWindow, dx: CGFloat, dy: CGFloat, camera: ARCamera) {
        guard window.pointsPerMeter > 1 else { return }

        let transform = camera.transform
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
