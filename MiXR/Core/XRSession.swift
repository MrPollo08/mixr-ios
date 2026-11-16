import ARKit
import Combine
import CoreVideo
import Foundation
import SwiftUI
import UIKit
import Vision
import simd

/// Pipeline híbrido XR para iPhone + Caja VR:
///
/// 1. **6DoF ARKit + Giroscopio (`HybridHeadTracker`)**: posición métrica + rotación
///    de baja latencia, fusionadas con el delta de CoreMotion a 100 Hz.
/// 2. **Mano 3D (`Vision` 21 pts + `LiDAR` + `Cuerpo/Brazo`) + filtro One-Euro**:
///    reconstrucción en metros reales de las 21 articulaciones **y del antebrazo**,
///    dibujada como una única silueta continua con relleno translúcido.
/// 3. **Capas**: escenario `z=0`, ventanas `z=100`, menú universal `z=500`,
///    mano `z=1000`.
///
/// No hay pantalla de menú principal: la app abre directo en la cámara. El menú
/// aparece con el gesto de **palma abierta + pinza**.
final class XRSession: NSObject, ObservableObject {

    // MARK: - Estado publicado

    @Published var handCount = 0
    @Published var handDepthText = "Sin manos"
    @Published var lidarActive = false
    @Published var armTracked = false
    @Published var status = ""
    @Published var localAddress = LocalIP.wifiAddress() ?? "sin Wi-Fi"
    @Published var mouseEnabled = false
    /// 2 = imagen completa de la cámara: nada recortado, ideal para el tracking de manos.
    @Published var framing = 2
    /// Autofoco continuo (true) o enfoque bloqueado (false, lo que evita el desenfoque).
    @Published var autofocusEnabled = false
    /// Mano fantasma (segmentación) en vez de la malla sintética.
    @Published var ghostHandEnabled = true

    var framingName: String {
        switch framing {
        case 0: return "Vista normal"
        case 1: return "Vista amplia"
        default: return "Cámara completa"
        }
    }

    private var visibleFraction: CGFloat {
        switch framing {
        case 0: return 0.615
        case 1: return 0.78
        default: return 1.0
        }
    }

    // MARK: - Modo VR box

    @Published var stereoEnabled = false {
        didSet { if stereoEnabled != oldValue { applyStereoMode() } }
    }
    @Published var vrScale: CGFloat = 0.5 { didSet { saveVRSettings() } }
    @Published var vrSeparation: CGFloat = 20 { didSet { saveVRSettings() } }
    @Published var vrVertical: CGFloat = 0 { didSet { saveVRSettings() } }

    // MARK: - Vistas y capas

    let backdrop = CameraSampleView()
    private let dim = UIView()
    let camera = CameraSampleView()
    let hostView = WindowHostView()
    /// Mano fantasma: recorte real de la cámara, translúcido, encima de las ventanas.
    let ghostView = HandGhostView()
    let overlay = HandOverlayView()

    private let leftPane = StereoPane()
    private let rightPane = StereoPane()
    private let stereoRoot = UIView()

    // MARK: - Motores

    private let arSession = ARSession()
    private let headTracker = HybridHeadTracker()
    private let tracker = HandTracker()
    private let gestures = GestureEngine()
    private let pointer = PointerController()
    private let input = InputClient()
    private let gamepad = GamepadController()

    private var displayLink: CADisplayLink?
    private var isRunning = false
    private var arStarted = false
    private var lastPose: CameraPose?
    private var lastHands: [HandPose] = []
    private var lastBuffer: CVPixelBuffer?
    private weak var monitor: SpatialWindow?
    private var gamepadMoving = false
    private var mapLoaded = false
    private var restoredMonitor = false

    // Predicción de movimiento (compensa la latencia de Vision entre frames).
    private var previousHands: [HandPose] = []
    private var previousHandsAt: CFTimeInterval = 0
    private var currentHandsAt: CFTimeInterval = 0
    /// Horizonte máximo de extrapolación y desplazamiento máximo permitido.
    private let predictionHorizon: CFTimeInterval = 0.045
    private let predictionMaxShiftRatio: CGFloat = 0.28

    lazy var containerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.clipsToBounds = true

        dim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        backdrop.videoGravity = .resizeAspectFill
        camera.videoGravity = .resize

        backdrop.layer.zPosition = 0
        dim.layer.zPosition = 1
        camera.layer.zPosition = 2
        hostView.layer.zPosition = 100
        ghostView.layer.zPosition = 900
        overlay.layer.zPosition = 1000

        for subview in [backdrop, dim, camera, hostView, ghostView, overlay] as [UIView] {
            subview.frame = view.bounds
            subview.autoresizingMask = []
            view.addSubview(subview)
        }

        hostView.session = self
        overlay.isUserInteractionEnabled = false
        overlay.showsSkeleton = false

        stereoRoot.frame = view.bounds
        stereoRoot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stereoRoot.backgroundColor = .black
        stereoRoot.layer.zPosition = 2000
        stereoRoot.isHidden = true
        view.addSubview(stereoRoot)
        stereoRoot.addSubview(leftPane)
        stereoRoot.addSubview(rightPane)
        leftPane.host.session = self
        rightPane.host.session = self

        // Doble toque en cualquier parte: alterna autofoco / enfoque bloqueado.
        // (No hay interfaz visible, así que este es el control de cámara.)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)

        // Triple toque: alterna mano fantasma / malla sintética.
        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap))
        tripleTap.numberOfTapsRequired = 3
        tripleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(tripleTap)
        doubleTap.require(toFail: tripleTap)

        return view
    }()

    @objc private func handleDoubleTap() {
        toggleAutofocus()
    }

    @objc private func handleTripleTap() {
        toggleHandVisual()
    }

    /// Alterna entre **mano fantasma** (segmentación, por defecto) y la malla sintética.
    func toggleHandVisual() {
        ghostHandEnabled.toggle()
        ghostView.isHidden = !ghostHandEnabled
        overlay.showsSkeleton = !ghostHandEnabled
        if !ghostHandEnabled { ghostView.clear() }
        status = ghostHandEnabled ? "Mano fantasma" : "Malla sintética"
    }

    override init() {
        super.init()
        gamepad.onPrimary = { [weak self] in self?.connectPC() }
        gamepad.onSecondary = { [weak self] in self?.centerWindows() }
        gamepad.onTertiary = { [weak self] in self?.toggleAutofocus() }
        gestures.onEvent = { [weak self] event in self?.handle(event) }
        loadVRSettings()
    }

    // MARK: - Ciclo de vida

    func start() {
        guard !isRunning else { return }
        isRunning = true
        localAddress = LocalIP.wifiAddress() ?? localAddress
        headTracker.start()
        startARKit()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func pause() {
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        headTracker.stop()
        arSession.pause()
        arStarted = false
        gestures.reset()
        ghostView.clear()
    }

    private func startARKit(forceReset: Bool = false) {
        guard ARWorldTrackingConfiguration.isSupported else {
            status = "Este iPhone no soporta ARKit"
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isLightEstimationEnabled = false
        configuration.environmentTexturing = .none

        // Enfoque: por defecto se BLOQUEA el autofoco continuo. Así la cámara deja de
        // "cazar" entre la mano (cerca) y el monitor (lejos), que es lo que producía
        // los parpadeos de desenfoque. Al bloquear, ARKit enfoca una vez y mantiene.
        configuration.isAutoFocusEnabled = autofocusEnabled

        if let format = Self.preferredVideoFormat() {
            configuration.videoFormat = format
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
            lidarActive = true
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
            lidarActive = true
        } else {
            lidarActive = false
        }

        if let map = loadWorldMap() {
            configuration.initialWorldMap = map
            mapLoaded = true
        }

        let reset = forceReset || !arStarted
        arSession.run(configuration, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
        arStarted = true
    }

    /// Formato de vídeo: se prefiere 30 fps (mejor en poca luz y menos ruido) con la
    /// resolución más alta que ARKit ofrezca para ese frame rate.
    private static func preferredVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        guard !formats.isEmpty else { return nil }

        let candidates = formats.filter { $0.framesPerSecond == 30 }
        let pool = candidates.isEmpty ? formats : candidates
        return pool.max { a, b in
            (a.imageResolution.width * a.imageResolution.height)
                < (b.imageResolution.width * b.imageResolution.height)
        }
    }

    /// Cambia entre autofoco continuo y enfoque bloqueado. Al bloquear se reinicia la
    /// sesión para que el foco quede fijado en la distancia a la que está tu mano ahora.
    func toggleAutofocus() {
        autofocusEnabled.toggle()
        startARKit(forceReset: false)
        status = autofocusEnabled ? "Autofoco continuo" : "Enfoque bloqueado"
    }

    // MARK: - Eventos de gestos

    private func handle(_ event: GestureEvent) {
        switch event {
        case .grabEnded:
            for window in hostView.windows { reanchor(window) }

        case .click(let point):
            if let window = hostView.window(at: point) {
                hostView.bringToFront(window)
            }

        case .scroll, .directTouch, .grabBegan:
            break
        }
    }

    // MARK: - Ventanas

    func connectPC() {
        if let monitor, hostView.windows.contains(where: { $0 === monitor }) {
            hostView.bringToFront(monitor)
            status = "Esperando al PC en \(localAddress):\(Config.streamPort)"
            return
        }

        let window = hostView.add(kind: .pcStream(port: Config.streamPort),
                                  position: positionInFront(distance: 1.6),
                                  physicalWidth: 0.85)
        monitor = window
        anchor(window)
        if stereoEnabled { buildMirrorWindows() }
        status = "Esperando al PC en \(localAddress):\(Config.streamPort)"
    }

    func closeWindows() {
        for window in hostView.windows {
            if let anchor = window.anchor {
                arSession.remove(anchor: anchor)
                window.anchor = nil
            }
        }
        hostView.removeAll()
        monitor = nil
        if stereoEnabled {
            leftPane.host.removeAll()
            rightPane.host.removeAll()
        }
    }

    func toggleMouse() {
        mouseEnabled.toggle()
        pointer.setEnabled(mouseEnabled)
        gestures.reset()
        status = mouseEnabled ? "Mouse del PC activo" : "Mouse del PC apagado"
    }

    func pcConnected(host: String) {
        input.connect(host: host)
        status = "PC conectado (\(host))"
    }

    func promptForURL(title: String, message: String, current: URL?, completion: @escaping (URL) -> Void) {}

    func cycleFraming() {
        framing = (framing + 1) % 3
    }

    func centerWindows() {
        headTracker.recenterGyro()
        for window in hostView.windows {
            if window === monitor {
                hostView.setPosition(window, positionInFront(distance: 1.6), force: true)
            } else {
                hostView.setPosition(window, positionInFront(distance: Config.windowDistance), force: true)
            }
            window.smoothedCenter = nil
            reanchor(window)
        }
    }

    /// Fija el monitor en la mesa detectada (plano real de ARKit).
    func snapMonitorToSurface() {
        guard let monitor else { return }
        guard let frame = arSession.currentFrame else { return }

        let viewport = hostView.bounds.size
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let results = frame.hitTest(center, types: [.existingPlaneUsingExtent,
                                                    .existingPlane,
                                                    .estimatedHorizontalPlane])
        guard let hit = results.first else { return }

        let t = hit.worldTransform.columns.3
        let position = simd_float3(t.x, t.y, t.z) + simd_float3(0, 0.30, 0)
        monitor.smoothedCenter = nil
        hostView.setPosition(monitor, position, force: true)
        reanchor(monitor)
    }

    // MARK: - Mapa del lugar

    private var mapURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dreamspace.worldmap")
    }

    private func loadWorldMap() -> ARWorldMap? {
        guard let mapURL, let data = try? Data(contentsOf: mapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    func savePlace() {
        guard monitor != nil else { return }
        arSession.getCurrentWorldMap { [weak self] map, _ in
            guard let self, let map, let mapURL = self.mapURL else { return }
            guard let data = try? NSKeyedArchiver.archivedData(withRootObject: map,
                                                               requiringSecureCoding: true) else { return }
            try? data.write(to: mapURL)
        }
    }

    private func restoreSavedMonitor() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "dreamspace.monitor.x") != nil else { return }
        if let monitor, hostView.windows.contains(where: { $0 === monitor }) { return }

        let position = simd_float3(Float(defaults.double(forKey: "dreamspace.monitor.x")),
                                   Float(defaults.double(forKey: "dreamspace.monitor.y")),
                                   Float(defaults.double(forKey: "dreamspace.monitor.z")))
        let width = CGFloat(defaults.double(forKey: "dreamspace.monitor.width"))
        let window = hostView.add(kind: .pcStream(port: Config.streamPort),
                                  position: position,
                                  physicalWidth: width > 0.2 ? width : 0.85)
        monitor = window
        anchor(window)
        if stereoEnabled { buildMirrorWindows() }
    }

    // MARK: - Anclajes

    private func anchor(_ window: SpatialWindow) {
        guard window.anchor == nil else { return }
        var matrix = matrix_identity_float4x4
        let p = window.position
        matrix.columns.3 = simd_float4(p.x, p.y, p.z, 1)
        let anchor = ARAnchor(transform: matrix)
        window.anchor = anchor
        arSession.add(anchor: anchor)
    }

    func reanchor(_ window: SpatialWindow) {
        if let old = window.anchor {
            arSession.remove(anchor: old)
            window.anchor = nil
        }
        anchor(window)
    }

    private func syncAnchors(dragging: Bool) {
        for window in hostView.windows {
            if window.anchor == nil { anchor(window) }
            guard !dragging, let anchor = window.anchor else { continue }
            let column = anchor.transform.columns.3
            let target = simd_float3(column.x, column.y, column.z)
            if simd_distance(target, window.position) > 0.004 {
                window.position = target
            }
        }
    }

    // MARK: - Loop principal

    @objc private func tick() {
        guard isRunning else { return }
        let screen = containerView.bounds.size
        guard screen.width > 1, screen.height > 1 else { return }
        guard let frame = arSession.currentFrame else { return }

        let orientation = ScreenOrientation.current
        let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage),
                               height: CVPixelBufferGetHeight(frame.capturedImage))
        let aspect = ScreenOrientation.displayAspect(raw: imageSize, orientation: orientation)

        let rect = Self.cameraRect(aspect: aspect, screen: screen, fraction: visibleFraction)

        camera.frame = rect
        ghostView.frame = rect
        hostView.bounds = CGRect(origin: .zero, size: rect.size)
        hostView.center = CGPoint(x: rect.midX, y: rect.midY)
        overlay.bounds = hostView.bounds
        overlay.center = hostView.center

        camera.enqueue(frame.capturedImage)
        backdrop.enqueue(frame.capturedImage)
        lastBuffer = frame.capturedImage

        let pose = headTracker.fusedPose(from: frame,
                                         orientation: orientation,
                                         viewport: rect.size,
                                         imageSize: imageSize)
        lastPose = pose

        if mapLoaded, !restoredMonitor, case .normal = frame.camera.trackingState {
            restoredMonitor = true
            restoreSavedMonitor()
        }

        overlay.render(poses: predictedHands())
        hostView.layout(pose: pose)

        // Mano fantasma: se alimenta con el frame *actual* de la cámara (60 Hz) y ella
        // misma limita la segmentación (~18 Hz). Así el recorte va pegado al video.
        ghostView.update(buffer: frame.capturedImage,
                         hands: lastHands,
                         orientation: orientation)

        if stereoEnabled {
            updateStereoPanes(pose: pose, buffer: frame.capturedImage, cameraSize: rect.size)
        }
        updateGamepad(pose: pose)

        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth

        tracker.submit(pixelBuffer: frame.capturedImage,
                       depthMap: depthData?.depthMap,
                       confidenceMap: depthData?.confidenceMap,
                       pose: pose,
                       viewportSize: rect.size,
                       imageAspect: aspect,
                       orientation: ScreenOrientation.visionOrientation(for: orientation)) { [weak self] poses in
            DispatchQueue.main.async { self?.apply(poses, pose: pose) }
        }
    }

    private static func cameraRect(aspect: CGFloat, screen: CGSize, fraction: CGFloat) -> CGRect {
        guard aspect > 0.1, screen.width > 1 else { return CGRect(origin: .zero, size: screen) }
        let height = screen.height / max(fraction, 0.2)
        let width = height * aspect
        return CGRect(x: (screen.width - width) / 2,
                      y: (screen.height - height) / 2,
                      width: width,
                      height: height)
    }

    private func apply(_ poses: [HandPose], pose: CameraPose) {
        previousHands = lastHands
        previousHandsAt = currentHandsAt
        currentHandsAt = CACurrentMediaTime()

        lastHands = poses
        if handCount != poses.count { handCount = poses.count }

        if let first = poses.first {
            let tag = first.hasLiDAR ? "LiDAR" : "3D"
            let text = String(format: "%@ · %.2f m", tag, first.depthMeters)
            if handDepthText != text { handDepthText = text }

            let armVisible = hypot(first.forearm.elbow2D.x - first.forearm.wrist2D.x,
                                   first.forearm.elbow2D.y - first.forearm.wrist2D.y) > first.palmScale * 0.8
            if armTracked != armVisible { armTracked = armVisible }
            if first.hasLiDAR != lidarActive { lidarActive = first.hasLiDAR }
        } else if handDepthText != "Sin manos" {
            handDepthText = "Sin manos"
            if armTracked { armTracked = false }
        }

        hostView.allowsPositionWrites = true

        if mouseEnabled {
            let ptr = pointer.update(poses: poses, viewport: hostView.bounds.size)
            overlay.setPointer(ptr)
            leftPane.overlay.setPointer(ptr)
            rightPane.overlay.setPointer(ptr)
            return
        }

        gestures.update(poses: poses, host: hostView, pose: pose)
        syncAnchors(dragging: gestures.isDragging || gamepadMoving)

        if let hand = poses.first {
            let probe = hand.joints[.indexTip] ?? hand.pinchPoint
            let activePoint = hostView.window(near: probe) != nil ? hand.pinchPoint : nil
            overlay.setPointer(activePoint)
            leftPane.overlay.setPointer(activePoint)
            rightPane.overlay.setPointer(activePoint)
        } else {
            overlay.setPointer(nil)
            leftPane.overlay.setPointer(nil)
            rightPane.overlay.setPointer(nil)
        }
    }

    // MARK: - Predicción de movimiento

    /// Extrapola las articulaciones hacia "ahora" con la velocidad medida entre los
    /// dos últimos frames de Vision. Vision corre a 30 Hz y la pantalla a 60/120 Hz:
    /// sin esto la malla va un frame por detrás de la mano real.
    private func predictedHands() -> [HandPose] {
        guard !lastHands.isEmpty, currentHandsAt > 0, previousHandsAt > 0 else { return lastHands }

        let now = CACurrentMediaTime()
        let elapsed = min(max(now - currentHandsAt, 0), predictionHorizon)
        guard elapsed > 0.002 else { return lastHands }

        let frameDelta = currentHandsAt - previousHandsAt
        guard frameDelta > 0.004 else { return lastHands }

        var result: [HandPose] = []
        for (index, hand) in lastHands.enumerated() {
            guard index < previousHands.count,
                  previousHands[index].key == hand.key else {
                result.append(hand)
                continue
            }
            let previous = previousHands[index]
            let maxShift = hand.palmScale * predictionMaxShiftRatio

            var joints = hand.joints
            for (name, point) in hand.joints {
                guard let old = previous.joints[name] else { continue }
                var dx = (point.x - old.x) / CGFloat(frameDelta) * CGFloat(elapsed)
                var dy = (point.y - old.y) / CGFloat(frameDelta) * CGFloat(elapsed)
                let magnitude = hypot(dx, dy)
                if magnitude > maxShift, magnitude > 0.001 {
                    dx *= maxShift / magnitude
                    dy *= maxShift / magnitude
                }
                joints[name] = CGPoint(x: point.x + dx, y: point.y + dy)
            }
            result.append(hand.replacingJoints(joints))
        }
        return result
    }

    // MARK: - Mando

    private func updateGamepad(pose: CameraPose) {
        let axes = gamepad.axes
        let moving = abs(axes.x) > 0.01 || abs(axes.y) > 0.01

        guard let monitor else {
            gamepadMoving = false
            return
        }

        guard moving else {
            if gamepadMoving {
                gamepadMoving = false
                reanchor(monitor)
            }
            return
        }

        let step = 1.0 / 60.0
        let right = pose.transform.columns.0
        let up = pose.transform.columns.1
        let delta = simd_float3(right.x, right.y, right.z) * Float(axes.x * step)
            + simd_float3(up.x, up.y, up.z) * Float(axes.y * step)
        hostView.setPosition(monitor, monitor.position + delta, force: true)
        gamepadMoving = true
    }

    // MARK: - VR box

    private func applyStereoMode() {
        stereoRoot.isHidden = !stereoEnabled
        for view in [backdrop, dim, camera, hostView, ghostView, overlay] as [UIView] {
            view.isHidden = stereoEnabled
        }

        if stereoEnabled {
            buildMirrorWindows()
        } else {
            leftPane.host.removeAll()
            rightPane.host.removeAll()
        }
    }

    private func buildMirrorWindows() {
        leftPane.host.removeAll()
        rightPane.host.removeAll()
        for window in hostView.windows {
            for pane in [leftPane, rightPane] {
                let copy = pane.host.add(kind: window.kind,
                                         position: window.position,
                                         physicalWidth: window.physicalWidth)
                copy.normal = window.normal
                copy.view.layer.zPosition = window.view.layer.zPosition
            }
        }
    }

    private func syncMirrorWindows() {
        let sources = hostView.windows
        for pane in [leftPane, rightPane] {
            guard pane.host.windows.count == sources.count else {
                buildMirrorWindows()
                return
            }
            for (source, mirror) in zip(sources, pane.host.windows) {
                mirror.position = source.position
                mirror.physicalWidth = source.physicalWidth
                mirror.normal = source.normal
                mirror.pinned = source.pinned
                mirror.view.isHidden = source.view.isHidden
                mirror.view.layer.zPosition = source.view.layer.zPosition
            }
        }
    }

    private func updateStereoPanes(pose: CameraPose, buffer: CVPixelBuffer, cameraSize: CGSize) {
        let size = containerView.bounds.size
        guard size.width > 10, size.height > 10 else { return }

        let half = CGSize(width: size.width / 2, height: size.height)
        leftPane.frame = CGRect(origin: .zero, size: half)
        rightPane.frame = CGRect(x: half.width, y: 0, width: half.width, height: half.height)

        leftPane.layoutScene(containerSize: cameraSize, scale: vrScale,
                             eyeShift: -vrSeparation / 2, verticalOffset: vrVertical)
        rightPane.layoutScene(containerSize: cameraSize, scale: vrScale,
                              eyeShift: vrSeparation / 2, verticalOffset: vrVertical)

        leftPane.background.enqueue(buffer)
        rightPane.background.enqueue(buffer)

        syncMirrorWindows()

        let leftEye = pose.eyePose(horizontalOffsetMeters: -0.032)
        let rightEye = pose.eyePose(horizontalOffsetMeters: 0.032)

        leftPane.host.layout(pose: leftEye)
        rightPane.host.layout(pose: rightEye)

        leftPane.render(poses: predictedHands().map { $0.projected(for: leftEye) })
        rightPane.render(poses: predictedHands().map { $0.projected(for: rightEye) })
    }

    // MARK: - Ajustes VR

    private func saveVRSettings() {
        let defaults = UserDefaults.standard
        defaults.set(Double(vrScale), forKey: "dreamspace.vrScale")
        defaults.set(Double(vrSeparation), forKey: "dreamspace.vrSeparation")
        defaults.set(Double(vrVertical), forKey: "dreamspace.vrVertical")
        defaults.set(stereoEnabled, forKey: "dreamspace.stereo")
    }

    private func loadVRSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "dreamspace.vrScale") != nil {
            vrScale = CGFloat(defaults.double(forKey: "dreamspace.vrScale"))
        }
        if defaults.object(forKey: "dreamspace.vrSeparation") != nil {
            vrSeparation = CGFloat(defaults.double(forKey: "dreamspace.vrSeparation"))
        }
        if defaults.object(forKey: "dreamspace.vrVertical") != nil {
            vrVertical = CGFloat(defaults.double(forKey: "dreamspace.vrVertical"))
        }
        if defaults.object(forKey: "dreamspace.stereo") != nil {
            stereoEnabled = defaults.bool(forKey: "dreamspace.stereo")
        }
    }

    private func positionInFront(distance: Float) -> simd_float3 {
        guard let pose = lastPose else { return simd_float3(0, 0, -distance) }
        let columns = pose.transform.columns
        let forward = simd_float3(-columns.2.x, -columns.2.y, -columns.2.z)
        let position = simd_float3(columns.3.x, columns.3.y, columns.3.z)
        return position + forward * distance
    }
}
