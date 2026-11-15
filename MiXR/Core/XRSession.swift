import ARKit
import Combine
import CoreVideo
import Foundation
import SwiftUI
import UIKit
import Vision
import simd

/// Dreamspace (monitor): un monitor grande de la PC clavado en el mundo real.
///
/// - ARKit 6DoF (una sola cámara: sin cambios, sin parpadeo).
/// - «Ver más»: muestra más campo de la cámara (zoom out por software) para que
///   el cuarto se sienta lejos y no "pegado a la cara".
/// - «Fijar en mesa»: escanea el plano y deja el monitor anclado ahí (ARAnchor).
/// - «Guardar lugar»: ARWorldMap + coordenadas; al volver, aparece solo.
/// - Manos: pinza en el borde = mover · dos pinzas = tamaño.
final class XRSession: NSObject, ObservableObject {

    // MARK: - Estado para SwiftUI

    @Published var handCount = 0
    @Published var status = "Tocá «Monitor PC» para empezar"
    @Published var localAddress = LocalIP.wifiAddress() ?? "sin Wi-Fi"
    @Published var mouseEnabled = false
    /// 0 = normal (llena), 1 = amplio, 2 = cámara completa (más lejos).
    @Published var framing = 1 {
        didSet { if framing != oldValue { status = framingName } }
    }

    var framingName: String {
        switch framing {
        case 0: return "Vista normal"
        case 1: return "Vista amplia"
        default: return "Cámara completa"
        }
    }

    /// Qué fracción del alto de la cámara se ve en pantalla (más chico = más
    /// lejos se ve el mundo).
    private var visibleFraction: CGFloat {
        switch framing {
        case 0: return 0.615
        case 1: return 0.78
        default: return 1.0
        }
    }

    // MARK: - Modo VR box

    /// Se muestra la pantalla de ajuste de los marcos antes de la cámara.
    @Published var showsSetup = true
    @Published var stereoEnabled = false {
        didSet { if stereoEnabled != oldValue { applyStereoMode() } }
    }
    /// Tamaño de cada ojo, separación y altura (se guardan).
    @Published var vrScale: CGFloat = 0.5 { didSet { saveVRSettings() } }
    @Published var vrSeparation: CGFloat = 20 { didSet { saveVRSettings() } }
    @Published var vrVertical: CGFloat = 0 { didSet { saveVRSettings() } }

    // MARK: - Vistas

    /// Fondo (llenando, atenuado) para los laterales cuando la cámara no llena.
    let backdrop = CameraSampleView()
    private let dim = UIView()
    /// Cámara nítida, en el rectángulo que corresponde.
    let camera = CameraSampleView()
    let hostView = WindowHostView()
    /// Dibuja la mano real **por encima** de las ventanas (efecto de agarre).
    let occlusionView = HandOcclusionView()
    let overlay = HandOverlayView()

    // Dos mitades, una por ojo (VR box).
    private let leftPane = StereoPane()
    private let rightPane = StereoPane()
    private let stereoRoot = UIView()

    // MARK: - Motor

    private let arSession = ARSession()
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
    /// Último frame de cámara (para la oclusión de la mano).
    private var lastBuffer: CVPixelBuffer?
    private weak var monitor: SpatialWindow?
    private var wasDragging = false
    private var gamepadMoving = false
    private var mapLoaded = false
    private var restoredMonitor = false

    lazy var containerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.clipsToBounds = true

        dim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        backdrop.videoGravity = .resizeAspectFill
        camera.videoGravity = .resize

        for subview in [backdrop, dim, camera, hostView, occlusionView, overlay] as [UIView] {
            subview.frame = view.bounds
            subview.autoresizingMask = []
            view.addSubview(subview)
        }

        hostView.session = self
        overlay.isUserInteractionEnabled = false
        overlay.showsSkeleton = false

        // VR box: dos mitades encima de todo.
        stereoRoot.frame = view.bounds
        stereoRoot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stereoRoot.backgroundColor = .black
        stereoRoot.isHidden = true
        view.addSubview(stereoRoot)
        stereoRoot.addSubview(leftPane)
        stereoRoot.addSubview(rightPane)
        leftPane.host.session = self
        rightPane.host.session = self

        return view
    }()

    override init() {
        super.init()
        gamepad.onPrimary = { [weak self] in self?.connectPC() }
        gamepad.onSecondary = { [weak self] in self?.snapMonitorToSurface() }
        loadVRSettings()
    }

    // MARK: - Ciclo de vida

    func start() {
        guard !isRunning else { return }
        isRunning = true
        localAddress = LocalIP.wifiAddress() ?? localAddress
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
        arSession.pause()
        arStarted = false
        gestures.reset()
        occlusionView.clear()
    }

    private func startARKit() {
        guard ARWorldTrackingConfiguration.isSupported else {
            status = "Este iPhone no soporta ARKit"
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal]
        configuration.isLightEstimationEnabled = false
        configuration.environmentTexturing = .none

        if let map = loadWorldMap() {
            configuration.initialWorldMap = map
            mapLoaded = true
        }

        arSession.run(configuration,
                      options: arStarted ? [] : [.resetTracking, .removeExistingAnchors])
        arStarted = true
    }

    // MARK: - Monitor de la PC

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
        status = "Monitor cerrado"
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

    /// Sin uso en esta versión (la ventana base lo declara).
    func promptForURL(title: String, message: String, current: URL?, completion: @escaping (URL) -> Void) {}

    /// Cambia cuánto campo de visión se ve (zoom out por software).
    func cycleFraming() {
        framing = (framing + 1) % 3
    }

    func centerMonitor() {
        guard let monitor else { return }
        hostView.setPosition(monitor, positionInFront(distance: 1.6), force: true)
        monitor.smoothedCenter = nil
        reanchor(monitor)
    }

    /// Escanea la mesa y fija el monitor ahí: coordenadas reales del plano.
    func snapMonitorToSurface() {
        guard let monitor else {
            status = "Primero abrí el monitor (Monitor PC)"
            return
        }
        guard let frame = arSession.currentFrame else { return }

        let viewport = hostView.bounds.size
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let results = frame.hitTest(center,
                                    types: [.existingPlaneUsingExtent,
                                            .existingPlane,
                                            .estimatedHorizontalPlane])
        guard let hit = results.first else {
            status = "No veo la superficie: mové el iPhone unos segundos sobre la mesa"
            return
        }

        let t = hit.worldTransform.columns.3
        let base = simd_float3(t.x, t.y, t.z)
        let position = base + simd_float3(0, 0.30, 0)

        if let pose = lastPose {
            let c = pose.transform.columns.3
            let direction = simd_float3(c.x, c.y, c.z) - position
            if simd_length(direction) > 0.1 {
                monitor.normal = simd_normalize(direction)
            }
        }

        monitor.smoothedCenter = nil
        hostView.setPosition(monitor, position, force: true)
        reanchor(monitor)

        let distance = lastPose?.project(position)?.depth ?? 0
        status = String(format: "Fijado en la mesa (%.1f m). Queda clavado ahí.", distance)
    }

    // MARK: - Mapa del lugar (pre-escaneo)

    private var mapURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dreamspace.worldmap")
    }

    private func loadWorldMap() -> ARWorldMap? {
        guard let mapURL, let data = try? Data(contentsOf: mapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    /// Guarda el mapa del lugar **y** dónde quedó el monitor.
    func savePlace() {
        guard let monitor else {
            status = "Primero abrí el monitor (Monitor PC)"
            return
        }
        persist(monitor)

        arSession.getCurrentWorldMap { [weak self] map, error in
            guard let self else { return }
            guard let map, let mapURL = self.mapURL else {
                DispatchQueue.main.async {
                    self.status = error?.localizedDescription
                        ?? "No pude guardar el mapa: mové el iPhone por la mesa unos segundos"
                }
                return
            }
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: map,
                                                            requiringSecureCoding: true)
                try data.write(to: mapURL)
                DispatchQueue.main.async {
                    self.status = "Lugar guardado: la próxima vez el monitor aparece acá solo"
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "No pude escribir el mapa: \(error.localizedDescription)"
                }
            }
        }
    }

    private func persist(_ window: SpatialWindow) {
        let defaults = UserDefaults.standard
        let p = window.position
        let n = window.normal
        defaults.set(Double(p.x), forKey: "dreamspace.monitor.x")
        defaults.set(Double(p.y), forKey: "dreamspace.monitor.y")
        defaults.set(Double(p.z), forKey: "dreamspace.monitor.z")
        defaults.set(Double(window.physicalWidth), forKey: "dreamspace.monitor.width")
        defaults.set(Double(n.x), forKey: "dreamspace.monitor.nx")
        defaults.set(Double(n.y), forKey: "dreamspace.monitor.ny")
        defaults.set(Double(n.z), forKey: "dreamspace.monitor.nz")
    }

    private func restoreSavedMonitor() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "dreamspace.monitor.x") != nil else { return }
        if let monitor, hostView.windows.contains(where: { $0 === monitor }) { return }

        let position = simd_float3(Float(defaults.double(forKey: "dreamspace.monitor.x")),
                                   Float(defaults.double(forKey: "dreamspace.monitor.y")),
                                   Float(defaults.double(forKey: "dreamspace.monitor.z")))
        let width = CGFloat(defaults.double(forKey: "dreamspace.monitor.width"))
        let normal = simd_float3(Float(defaults.double(forKey: "dreamspace.monitor.nx")),
                                 Float(defaults.double(forKey: "dreamspace.monitor.ny")),
                                 Float(defaults.double(forKey: "dreamspace.monitor.nz")))

        let window = hostView.add(kind: .pcStream(port: Config.streamPort),
                                  position: position,
                                  physicalWidth: width > 0.2 ? width : 0.85)
        window.normal = simd_length(normal) > 0.1 ? normal : window.normal
        monitor = window
        anchor(window)
        status = "Monitor restaurado del lugar guardado"
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

    // MARK: - Frames

    @objc private func tick() {
        guard isRunning else { return }
        let screen = containerView.bounds.size
        guard screen.width > 1, screen.height > 1 else { return }
        guard let frame = arSession.currentFrame else { return }

        let orientation = ScreenOrientation.current
        let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage),
                               height: CVPixelBufferGetHeight(frame.capturedImage))
        let aspect = ScreenOrientation.displayAspect(raw: imageSize, orientation: orientation)

        // Rectángulo de la cámara: con "ver más" se agranda y se ven más grados.
        let rect = Self.cameraRect(aspect: aspect, screen: screen, fraction: visibleFraction)

        camera.frame = rect
        occlusionView.frame = rect
        occlusionView.isHidden = stereoEnabled
        hostView.bounds = CGRect(origin: .zero, size: rect.size)
        hostView.center = CGPoint(x: rect.midX, y: rect.midY)
        overlay.bounds = hostView.bounds
        overlay.center = hostView.center

        camera.enqueue(frame.capturedImage)
        backdrop.enqueue(frame.capturedImage)
        lastBuffer = frame.capturedImage
        let pose = CameraPose(arkitCamera: frame.camera,
                              orientation: orientation,
                              viewport: rect.size,
                              imageSize: imageSize)
        lastPose = pose

        // Si había un lugar guardado y ya re-localizó, aparece el monitor solo.
        if mapLoaded, !restoredMonitor, case .normal = frame.camera.trackingState {
            restoredMonitor = true
            restoreSavedMonitor()
        }

        overlay.render(poses: lastHands)
        hostView.layout(pose: pose)
        if stereoEnabled {
            updateStereoPanes(pose: pose, buffer: frame.capturedImage, cameraSize: rect.size)
        }
        updateGamepad(pose: pose)

        tracker.submit(pixelBuffer: frame.capturedImage,
                       viewportSize: rect.size,
                       imageAspect: aspect,
                       orientation: ScreenOrientation.visionOrientation(for: orientation)) { [weak self] poses in
            DispatchQueue.main.async { self?.apply(poses, pose: pose) }
        }
    }

    private static func cameraRect(aspect: CGFloat,
                                   screen: CGSize,
                                   fraction: CGFloat) -> CGRect {
        guard aspect > 0.1, screen.width > 1 else { return CGRect(origin: .zero, size: screen) }
        let height = screen.height / max(fraction, 0.2)
        let width = height * aspect
        return CGRect(x: (screen.width - width) / 2,
                      y: (screen.height - height) / 2,
                      width: width,
                      height: height)
    }

    private func apply(_ poses: [HandPose], pose: CameraPose) {
        lastHands = poses
        if handCount != poses.count { handCount = poses.count }

        // La mano real se dibuja encima de las ventanas: así "agarra" de verdad.
        if poses.isEmpty {
            occlusionView.clear()
        } else {
            occlusionView.update(buffer: lastBuffer,
                                 hands: poses,
                                 orientation: ScreenOrientation.current)
        }

        hostView.allowsPositionWrites = true

        if mouseEnabled {
            overlay.setPointer(pointer.update(poses: poses, viewport: hostView.bounds.size))
            return
        }

        gestures.update(poses: poses, host: hostView, pose: pose)

        if wasDragging, !gestures.isDragging, let monitor {
            reanchor(monitor)
        }
        wasDragging = gestures.isDragging

        syncAnchors(dragging: gestures.isDragging || gamepadMoving)

        if let tip = poses.first.map({ $0.pinchPoint }),
           hostView.window(near: tip) != nil {
            overlay.setPointer(tip)
        } else {
            overlay.setPointer(nil)
        }
    }

    // MARK: - Mando Bluetooth

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
        let speed: CGFloat = 1.0
        let right = pose.transform.columns.0
        let up = pose.transform.columns.1
        let delta = simd_float3(right.x, right.y, right.z) * Float(axes.x * speed * step)
            + simd_float3(up.x, up.y, up.z) * Float(axes.y * speed * step)
        hostView.setPosition(monitor, monitor.position + delta, force: true)
        gamepadMoving = true
    }

    // MARK: - Modo VR box (dos mitades)

    private func applyStereoMode() {
        stereoRoot.isHidden = !stereoEnabled
        for view in [backdrop, dim, camera, hostView, occlusionView, overlay] as [UIView] {
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
                _ = pane.host.add(kind: window.kind,
                                  position: window.position,
                                  physicalWidth: window.physicalWidth)
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
                mirror.pinned = source.pinned
                mirror.view.isHidden = source.view.isHidden
            }
        }
    }

    /// Dibuja la escena en las dos mitades. `cameraSize` es el rectángulo que
    /// ocupa la cámara, así el zoom elegido se respeta en el visor.
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
        leftPane.host.layout(pose: pose)
        rightPane.host.layout(pose: pose)
        leftPane.render(poses: lastHands)
        rightPane.render(poses: lastHands)
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

    /// Pasa de la pantalla de ajuste a la cámara.
    func startCamera() {
        showsSetup = false
        start()
    }

    /// Vuelve al ajuste de los marcos.
    func openSetup() {
        showsSetup = true
    }

    // MARK: - Utilidades

    private func positionInFront(distance: Float) -> simd_float3 {
        guard let pose = lastPose else { return simd_float3(0, 0, -distance) }
        let columns = pose.transform.columns
        let forward = simd_float3(-columns.2.x, -columns.2.y, -columns.2.z)
        let position = simd_float3(columns.3.x, columns.3.y, columns.3.z)
        return position + forward * distance
    }
}
