import UIKit
import simd

/// Contenido desplazable (scroll con la pinza mantenida).
protocol ScrollableContent: AnyObject {
    @discardableResult
    func scroll(atLocal point: CGPoint, deltaY: CGFloat) -> Bool
}

/// Contenido que acepta un clic/toque directo sobre sus elementos.
protocol ClickableContent: AnyObject {
    @discardableResult
    func click(atLocal point: CGPoint) -> Bool
}

/// Contiene las ventanas flotantes y las proyecta al espacio real.
///
/// Todo el cálculo pasa por `CameraPose`, así funciona igual con ARKit (6DoF)
/// o con la cámara gran angular (3DoF).
final class WindowHostView: UIView {

    weak var session: XRSession?
    var onCountChanged: ((Int) -> Void)?

    private(set) var windows: [SpatialWindow] = []
    private(set) var lastPose: CameraPose?

    /// Proyector provisto por quien dibuja el fondo (SceneKit): devuelve el
    /// centro en pantalla y los puntos por metro de un punto del mundo.
    /// Usar el mismo motor que el fondo evita cualquier desincronización.
    struct WorldProjection {
        let center: CGPoint
        let pointsPerMeter: CGFloat
    }

    var worldToScreen: ((simd_float3) -> WorldProjection)?

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
                                     showsLinkButton: kind.showsLinkButton,
                                     showsCloseButton: kind.showsCloseButton)
        view.isHidden = true

        let window = SpatialWindow(kind: kind,
                                   position: position,
                                   physicalWidth: physicalWidth,
                                   view: view)

        let content = kind.makeContent()
        view.setContent(content)

        // Todas las ventanas de escenario viven en la capa de mundo (z = 100).
        view.layer.zPosition = 100

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

        if let pressable = content as? SpatialPressable {
            window.pressAt = { [weak self, weak pressable, weak view] point in
                guard let self, let pressable, let view else { return false }
                return pressable.press(atLocal: view.convert(point, from: self))
            }
            window.hoverAt = { [weak self, weak pressable, weak view] point, dt in
                guard let self, let pressable, let view else { return }
                guard let point else {
                    pressable.updatePointer(atLocal: nil, dt: dt)
                    return
                }
                pressable.updatePointer(atLocal: view.convert(point, from: self), dt: dt)
            }
        }

        // Scroll y clic sobre el contenido (gestos de pinza mantenida y Direct Touch).
        if let scrollable = content as? ScrollableContent {
            window.scrollAt = { [weak self, weak scrollable, weak view] point, delta in
                guard let self, let scrollable, let view else { return false }
                return scrollable.scroll(atLocal: view.convert(point, from: self),
                                         deltaY: delta.height)
            }
        }
        if let clickable = content as? ClickableContent {
            window.clickAt = { [weak self, weak clickable, weak view] point in
                guard let self, let clickable, let view else { return false }
                return clickable.click(atLocal: view.convert(point, from: self))
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

        // El panel queda mirando hacia donde estaba la cámara al crearlo.
        if let pose = lastPose {
            window.normal = simd_float3(pose.transform.columns.2.x,
                                        pose.transform.columns.2.y,
                                        pose.transform.columns.2.z)
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

    func removeAll(except keep: SpatialWindow? = nil) {
        for window in windows where window !== keep {
            window.view.removeFromSuperview()
        }
        windows.removeAll { $0 !== keep }
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

    /// Rectángulo que ocupa la ventana en pantalla (aproximado: ignora la inclinación 3D).
    /// Lo usan los gestos de Direct Touch y scroll.
    func screenFrame(for window: SpatialWindow) -> CGRect? {
        guard !window.view.isHidden, window.pointsPerMeter > 1 else { return nil }
        let base = window.view.baseSize
        guard base.width > 1 else { return nil }
        let scale = (window.physicalWidth * window.pointsPerMeter) / base.width
        guard scale.isFinite, scale > 0.001 else { return nil }
        let w = base.width * scale
        let h = base.height * scale
        return CGRect(x: window.view.center.x - w / 2,
                      y: window.view.center.y - h / 2,
                      width: w, height: h)
    }

    /// Sólo un arrastre activo (o un recentrado explícito) puede mover una
    /// ventana. Cualquier otra escritura se descarta: garantiza world-lock.
    var allowsPositionWrites = false

    func setPosition(_ window: SpatialWindow, _ position: simd_float3, force: Bool = false) {
        guard force || allowsPositionWrites else { return }
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
        guard let pose = lastPose else {
            window.view.isHidden = true
            return
        }

        guard let projection = pose.project(window.position) else {
            window.view.isHidden = true
            return
        }

        // De espaldas: el panel no se dibuja (es un objeto, no un HUD).
        if isFacingAway(window: window, pose: pose) {
            window.view.isHidden = true
            return
        }

        // Preferimos la proyección del renderer del fondo (SceneKit).
        var center = projection.center
        var pointsPerMeter = projection.pointsPerMeter
        if let projector = worldToScreen {
            let rendered = projector(window.position)
            if rendered.pointsPerMeter.isFinite, rendered.pointsPerMeter > 0.1,
               rendered.center.x.isFinite, rendered.center.y.isFinite {
                center = rendered.center
                pointsPerMeter = rendered.pointsPerMeter
            }
        }

        window.pointsPerMeter = pointsPerMeter
        window.view.isHidden = false
        window.view.bounds = CGRect(origin: .zero, size: window.view.baseSize)
        let previous = window.smoothedCenter ?? center
        // Tracking limitado (poca luz/textura): más calma, menos temblor.
        // Factor alto = el panel sigue al mundo casi sin retraso (antes 0.35 se notaba como lag).
        let smoothing: CGFloat = pose.trackingLimited ? 0.45 : 0.72
        let smoothed = CGPoint(x: previous.x + (center.x - previous.x) * smoothing,
                               y: previous.y + (center.y - previous.y) * smoothing)
        window.smoothedCenter = smoothed
        window.view.center = smoothed

        let targetWidth = window.physicalWidth * pointsPerMeter
        let scale = targetWidth / window.view.baseSize.width
        window.view.transform = .identity
        window.view.layer.transform = panelTransform(window: window, pose: pose, scale: scale)

        // Se atenúa un poco con la distancia (efecto de profundidad).
        let fade = CGFloat(1.35 - projection.depth * 0.09)
        window.view.alpha = min(1, max(0.35, fade))
    }


    /// Transformación 3D real del panel: se inclina según desde dónde lo mires.
    /// Sin esto las ventanas eran "billboard" (siempre de frente).
    private func panelTransform(window: SpatialWindow, pose: CameraPose, scale: CGFloat) -> CATransform3D {
        let cameraPosition = simd_float3(pose.transform.columns.3.x,
                                         pose.transform.columns.3.y,
                                         pose.transform.columns.3.z)
        let delta = cameraPosition - window.position
        let normal = window.normal

        var right = simd_cross(simd_float3(0, 1, 0), normal)
        if simd_length(right) < 0.01 { right = simd_float3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(normal, right))

        let localX = simd_dot(delta, right)
        let localY = simd_dot(delta, up)
        let localZ = max(simd_dot(delta, normal), 0.01)

        let yaw = atan2(CGFloat(localX), CGFloat(localZ))
        let pitch = atan2(CGFloat(localY), CGFloat(hypot(localX, localZ)))

        var transform = CATransform3DIdentity
        // Perspectiva físicamente correcta: la fuerza de la fuga es 1 / distancia focal
        // (en puntos). Antes era una constante inventada, por eso el panel se veía plano.
        let focal = CGFloat(max((pose.focalX + pose.focalY) * 0.5, 200))
        transform.m34 = -1.0 / focal
        transform = CATransform3DRotate(transform, -yaw, 0, 1, 0)
        transform = CATransform3DRotate(transform, pitch, 1, 0, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return transform
    }

    /// Verdadero si el panel está de espaldas a la cámara (hay que ocultarlo).
    private func isFacingAway(window: SpatialWindow, pose: CameraPose) -> Bool {
        let cameraPosition = simd_float3(pose.transform.columns.3.x,
                                         pose.transform.columns.3.y,
                                         pose.transform.columns.3.z)
        let toCamera = simd_normalize(cameraPosition - window.position)
        return simd_dot(window.normal, toCamera) < 0.12
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

    /// Ventana bajo el punto o cerca (margen): sirve para mostrar el cursor
    /// cuando la mano se acerca, sin tener que estar justo encima.
    func window(near point: CGPoint, margin: CGFloat = 46) -> SpatialWindow? {
        for window in windows.reversed() where !window.view.isHidden {
            if window.view.frame.insetBy(dx: -margin, dy: -margin).contains(point) { return window }
        }
        return nil
    }

    func window(at point: CGPoint) -> SpatialWindow? {
        for window in windows.reversed() where !window.view.isHidden {
            if window.view.frame.contains(point) { return window }
        }
        return nil
    }

    /// Ventana cuyo **borde** está cerca del punto: es donde se pellizca para
    /// agarrar el monitor (el centro queda libre para el contenido).
    func window(nearBorder point: CGPoint, margin: CGFloat = 54) -> SpatialWindow? {
        for window in windows.reversed() where !window.view.isHidden {
            let outer = window.view.frame.insetBy(dx: -margin, dy: -margin)
            let inner = window.view.frame.insetBy(dx: margin, dy: margin)
            if outer.contains(point), !inner.contains(point) { return window }
        }
        return nil
    }

    /// Rectángulo de la barra de agarre de una ventana, en coordenadas del host
    /// (el panel está dibujado con `layer.transform`, así que se escala igual).
    func grabBarRect(for window: SpatialWindow, margin: CGFloat = 20) -> CGRect {
        guard !window.view.isHidden else { return .zero }
        let bar = window.view.grabBarFrame
        let base = window.view.baseSize
        guard bar.width > 0.5, base.width > 1, window.pointsPerMeter > 1 else { return .zero }

        let scale = (window.physicalWidth * window.pointsPerMeter) / base.width
        let center = window.view.center
        let rect = CGRect(x: center.x + (bar.minX - base.width / 2) * scale,
                          y: center.y + (bar.minY - base.height / 2) * scale,
                          width: bar.width * scale,
                          height: bar.height * scale)
        guard rect.width.isFinite, rect.height.isFinite else { return .zero }
        return rect.insetBy(dx: -margin, dy: -margin * 0.5)
    }

    /// ¿La mano está sobre la barra de alguna ventana? Es el agarre.
    func window(atBar point: CGPoint) -> SpatialWindow? {
        for window in windows.reversed() where !window.view.isHidden {
            let rect = grabBarRect(for: window)
            if rect.width > 0, rect.contains(point) { return window }
        }
        return nil
    }
}
