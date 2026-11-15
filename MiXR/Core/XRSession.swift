import ARKit
import AVFoundation
import Combine
import CoreVideo
import PhotosUI
import SceneKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import simd

/// Con qué cámara se ve el mundo.
enum CameraMode: Equatable {
    /// Ultra gran angular 0.5x (AVFoundation + CoreMotion, 3DoF).
    /// Mucho más campo de visión: ideal para manos y para el efecto visor.
    case ultraWide
    /// Cámara normal con ARKit (6DoF, anclaje real al mundo).
    case arkit

    var label: String {
        switch self {
        case .ultraWide: return "0.5×"
        case .arkit: return "1×"
        }
    }

    var trackingLabel: String {
        switch self {
        case .ultraWide: return "gran angular · 3DoF"
        case .arkit: return "normal · 6DoF"
        }
    }
}

/// Orquesta todo: cámara (ARKit o gran angular), tracking de manos con Vision,
/// ventanas flotantes ancladas al mundo y oclusión de manos.
final class XRSession: NSObject, ObservableObject, PHPickerViewControllerDelegate {

    // MARK: - Estado que consume SwiftUI

    @Published var handCount = 0
    @Published var windowCount = 0
    @Published var handsVisible = true
    @Published var unsupportedMessage: String?
    /// Modo control: la mano maneja el mouse del PC en vez de mover ventanas.
    @Published var controlMode = false
    /// IP del PC conectado (se detecta sola cuando llega el stream).
    @Published var pcHost: String?

    @Published private(set) var cameraMode: CameraMode = XRSession.savedMode()
    @Published private(set) var occlusionEnabled = false
    /// Modo VR: la escena se dibuja dos veces, una por ojo.
    @Published var stereoEnabled = true {
        didSet { if stereoEnabled != oldValue { applyStereoMode() } }
    }
    /// Ajustes del marco de las gafas (pantalla previa a la cámara).
    @Published var vrScale: CGFloat = 0.5 { didSet { saveVRSettings() } }
    @Published var vrSeparation: CGFloat = 20 { didSet { saveVRSettings() } }
    @Published var vrVertical: CGFloat = 0 { didSet { saveVRSettings() } }
    /// Si está en true se muestra la pantalla de ajuste en vez de la cámara.
    @Published var showsSetup = true

    private let leftPane = StereoPane()
    private let rightPane = StereoPane()
    private let stereoRoot = UIView()

    override init() {
        super.init()
        loadVRSettings()
    }

    private static let modeKey = "mixr.cameraMode"

    /// Siempre 1× con ARKit (6DoF): es el único modo donde las ventanas quedan
    /// clavadas en el mundo y no te siguen. La 0.5× no tiene traslación, así
    /// que se descartó (quedó el código por si algún día vuelve como opción).
    private static func savedMode() -> CameraMode {
        UserDefaults.standard.removeObject(forKey: modeKey)
        return .arkit
    }

    private func saveMode() {
        UserDefaults.standard.removeObject(forKey: Self.modeKey)
    }

    // MARK: - Vistas de UIKit

    let sceneView = ARSCNView()
    let cameraSampleView = CameraSampleView()
    let wideView = WideCameraView()
    let hostView = WindowHostView()
    let occlusionView = HandOcclusionView()
    let overlay = HandOverlayView()

    private let arSession = ARSession()
    private let tracker = HandTracker()
    private let gestures = GestureEngine()
    let pointer = PointerController()

    private var isRunning = false
    private var displayLink: CADisplayLink?
    private var lastPose: CameraPose?
    private var lastHands: [HandPose] = []
    /// Distancia real al dedo (LiDAR) en metros.
    private var handDepth: Float?
    private weak var menuWindow: SpatialWindow?
    /// El buffer de la 0.5× que ARKit captura por dentro resultó ser una imagen
    /// de **baja resolución** (pensada para tracking, no para mostrar): se veía
    /// borrosa y sólo llegaba en algunos frames. Apagado: usamos la imagen
    /// propia de ARKit, que es nítida y llega a 60 fps.
    private static let useUltraWideImage = false

    /// SceneKit puede devolver una cámara vieja si la vista no se está
    /// renderizando (modo VR). Proyectamos con ARKit, que siempre está al día.
    private static let useSceneKitProjector = false

    /// Cuántas veces se lanzó ARKit y cuántos frames llegaron (diagnóstico).
    private var arkitRuns = 0
    private var frameCount = 0

    /// Último frame bueno de la 0.5× (el buffer aparece sólo en algunos frames,
    /// así que se reutiliza para que el fondo no parpadee).
    private var ultraWideBuffer: CVPixelBuffer?
    private var ultraWideAt: CFTimeInterval = 0

    /// FPS reales de entrega de ARKit (diagnóstico).
    private var lastFrameTime: TimeInterval = 0
    private var smoothedFPS: Double = 0

    /// Diagnóstico en pantalla (posición de la cámara y estado del tracking).
    @Published var debugText = ""
    private var lastDebugAt: CFTimeInterval = 0

    /// Contenedor único que se entrega a SwiftUI.
    lazy var containerView: UIView = {        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.clipsToBounds = true

        // De abajo a arriba: cámara, ventanas, manos (oclusión), esqueleto.
        let stack: [UIView] = [cameraSampleView, sceneView, wideView, hostView, occlusionView, overlay]
        for subview in stack {
            subview.frame = view.bounds
            subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(subview)
        }

        // Modo VR: dos mitades, una por ojo.
        stereoRoot.frame = view.bounds
        stereoRoot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stereoRoot.backgroundColor = .black
        stereoRoot.isHidden = true
        view.addSubview(stereoRoot)
        stereoRoot.addSubview(leftPane)
        stereoRoot.addSubview(rightPane)
        leftPane.host.session = self
        rightPane.host.session = self

        cameraSampleView.isHidden = true
        sceneView.isUserInteractionEnabled = false
        wideView.isUserInteractionEnabled = false
        occlusionView.isUserInteractionEnabled = false
        overlay.isUserInteractionEnabled = false

        hostView.session = self
        hostView.onCountChanged = { [weak self] count in
            guard let self, self.windowCount != count else { return }
            self.windowCount = count
        }

        applyModeVisibility()
        applyStereoMode()
        return view
    }()


    // MARK: - Ajustes previos y arranque

    /// Pasa de la pantalla de ajuste a la c�mara.
    func startCamera() {
        showsSetup = false
        start()
    }

    /// Vuelve a la pantalla de ajuste (para calibrar el marco de las gafas).
    func openSetup() {
        pause()
        showsSetup = true
    }

    private func saveVRSettings() {
        let defaults = UserDefaults.standard
        defaults.set(Double(vrScale), forKey: "mixr.vrScale")
        defaults.set(Double(vrSeparation), forKey: "mixr.vrSeparation")
        defaults.set(Double(vrVertical), forKey: "mixr.vrVertical")
        defaults.set(stereoEnabled, forKey: "mixr.stereo")
    }

    private func loadVRSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "mixr.vrScale") != nil {
            vrScale = CGFloat(defaults.double(forKey: "mixr.vrScale"))
        }
        if defaults.object(forKey: "mixr.vrSeparation") != nil {
            vrSeparation = CGFloat(defaults.double(forKey: "mixr.vrSeparation"))
        }
        if defaults.object(forKey: "mixr.vrVertical") != nil {
            vrVertical = CGFloat(defaults.double(forKey: "mixr.vrVertical"))
        }
    }
        // MARK: - Ciclo de vida

    func start() {
        guard !isRunning else { return }
        gestures.onSummon = { [weak self] in
            self?.summonMenu()
        }

        requestCameraPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.unsupportedMessage = "Falta el permiso de cámara. Activalo en Ajustes → MiXR."
                return
            }
            self.beginSession()
        }
    }

    private func requestCameraPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func beginSession() {
        if cameraMode == .arkit, !ARWorldTrackingConfiguration.isSupported {
            cameraMode = .ultraWide
        }

        switch cameraMode {
        case .arkit:
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.planeDetection = [.horizontal]

            // LiDAR: malla del entorno. Sin esto, en paredes lisas ARKit queda
            // en 'limited' y pierde la traslación (la ventana te sigue en Z).
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                configuration.sceneReconstruction = .meshWithClassification
            }
            configuration.isLightEstimationEnabled = false
            configuration.environmentTexturing = .none

            // LiDAR: profundidad real de la mano (sólo en modelos Pro).
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }

            sceneView.session = arSession
            sceneView.automaticallyUpdatesLighting = false
            sceneView.antialiasingMode = .none
            sceneView.preferredFramesPerSecond = 60

            // CLAVE: sólo el primer lanzamiento resetea el origen del mundo.
            // Si se resetea de nuevo, el origen se mueve a donde estás parado y
            // todo lo que estaba delante tuyo vuelve a aparecer delante tuyo
            // (parece que las ventanas te siguen).
            let options: ARSession.RunOptions = arkitRuns == 0
                ? [.resetTracking, .removeExistingAnchors]
                : []
            arSession.run(configuration, options: options)
            arkitRuns += 1
            wideView.stop()

        case .ultraWide:
            arSession.pause()
            wideView.start()
        }

        applyModeVisibility()
        applyStereoMode()

        // Los frames se leen acá (no con el delegate de ARSession) para no
        // pelearse con ARSCNView, que necesita quedarse con ese delegate.
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link

        isRunning = true
        configureAudio()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func pause() {
        guard isRunning else { return }
        displayLink?.invalidate()
        displayLink = nil
        arSession.pause()
        wideView.stop()
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func configureAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Sin audio la app sigue siendo usable.
        }
    }

    private func applyModeVisibility() {
        wideView.isHidden = cameraMode != .ultraWide
        sceneView.isHidden = cameraMode != .arkit
        occlusionView.isHidden = !occlusionEnabled
        if occlusionView.isHidden { occlusionView.clear() }
        // cameraSampleView queda oculto salvo que se use la imagen 0.5×.
    }

    // MARK: - Cambiar de cámara / oclusión

    func toggleCameraMode() {
        setCameraMode(cameraMode == .ultraWide ? .arkit : .ultraWide)
    }

    func setCameraMode(_ mode: CameraMode) {
        guard mode != cameraMode else { return }
        let wasRunning = isRunning
        pause()

        cameraMode = mode
        saveMode()
        lastPose = nil
        lastHands = []
        overlay.render(poses: [])
        overlay.setPointer(nil)
        gestures.reset()

        if wasRunning { start() }
    }

    func toggleOcclusion() {
        occlusionEnabled.toggle()
        applyModeVisibility()
    }

    /// Toma la orientación actual como "adelante" y trae el menú delante tuyo.
    func recenterView() {
        switch cameraMode {
        case .ultraWide:
            wideView.recenter()
            placeMenuFront(transform: matrix_identity_float4x4)
        case .arkit:
            placeMenuFront(transform: lastPose?.transform ?? matrix_identity_float4x4)
        }
    }

    /// Doble pinza al aire: trae el menú delante de la cámara.
    func summonMenu() {
        ensureMenu()
        placeMenuFront(transform: lastPose?.transform ?? matrix_identity_float4x4)
    }

    /// Alterna el menú entre **anclado al mundo** y **pegado a la cara**.
    func togglePinnedMenu() {
        guard let menu = menuWindow else { return }
        if !menu.pinned, let pose = lastPose, let projection = pose.project(menu.position) {
            menu.pinnedDistance = projection.depth
        }
        menu.pinned.toggle()
        if let pose = lastPose {
            hostView.layout(pose: pose)
        }
    }

    // MARK: - Menú flotante

    private func ensureMenu() {
        if let existing = menuWindow, hostView.windows.contains(where: { $0 === existing }) {
            return
        }
        let position = positionInFrontOfCamera(index: 0, distance: Config.menuDistance)
        let window = hostView.add(kind: .menu, position: position, physicalWidth: Config.menuWidth)
        menuWindow = window

        (window.view.content as? MenuContentView)?.onAction = { [weak self] action in
            self?.handleMenu(action)
        }
    }

    private func placeMenuFront(transform: simd_float4x4) {
        guard let menu = menuWindow else {
            ensureMenu()
            return
        }
        let position = positionInFrontOfCamera(index: 0,
                                               distance: Config.menuDistance,
                                               transform: transform)
        hostView.setPosition(menu, position, force: true)
        hostView.bringToFront(menu)
    }

    private func handleMenu(_ action: MenuAction) {
        switch action {
        case .pc: addPCWindow()
        case .youtube: addWebWindow(url: Config.youtubeURL)
        case .video: addVideoWindow(url: Config.sampleVideoURL)
        case .photos: pickVideo()
        case .web: addWebWindow(url: Config.defaultWebURL)
        case .control: toggleControlMode()
        case .hands: toggleHands()
        case .occlusion: toggleOcclusion()
        case .stereo: stereoEnabled.toggle()
        case .recenter: recenterView()
        case .clear: closeAllWindows()
        }
    }

    // MARK: - Frames

    @objc private func tick() {
        guard isRunning else { return }
        let viewport = containerView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return }

        let orientation = ScreenOrientation.current
        var pose: CameraPose?
        var buffer: CVPixelBuffer?

        switch cameraMode {
        case .arkit:
            if let frame = arSession.currentFrame {
                frameCount += 1
                let now = CACurrentMediaTime()

                let delta = frame.timestamp - lastFrameTime
                if delta > 0.001, delta < 1 {
                    let instant = 1 / delta
                    smoothedFPS = smoothedFPS < 1 ? instant : smoothedFPS * 0.9 + instant * 0.1
                }
                lastFrameTime = frame.timestamp

                let candidate = ARFrameUltraWide.pixelBuffer(from: frame)
                    .flatMap { Self.isUsable($0) ? $0 : nil }
                if let candidate {
                    ultraWideBuffer = candidate
                    ultraWideAt = now
                }

                let useUltraWide = ultraWideBuffer != nil && now - ultraWideAt < 0.5

                if Self.useUltraWideImage, useUltraWide, let validUltraWide = ultraWideBuffer {
                    // 6DoF de ARKit + imagen de la 0.5×, compuesta en GPU.
                    cameraSampleView.isHidden = false
                    sceneView.isHidden = true
                    cameraSampleView.enqueue(validUltraWide)

                    let size = CGSize(width: CVPixelBufferGetWidth(validUltraWide),
                                      height: CVPixelBufferGetHeight(validUltraWide))
                    pose = CameraPose(cameraTransform: frame.camera.transform,
                                      orientation: orientation,
                                      viewport: viewport,
                                      imageSize: size,
                                      longFieldOfView: Config.ultraWideLongFieldOfView * .pi / 180)
                    buffer = validUltraWide
                } else {
                    cameraSampleView.isHidden = true
                    sceneView.isHidden = false

                    let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage),
                                           height: CVPixelBufferGetHeight(frame.capturedImage))
                    pose = CameraPose(arkitCamera: frame.camera,
                                      orientation: orientation,
                                      viewport: viewport,
                                      imageSize: imageSize)
                    buffer = frame.capturedImage
                }

                updateDebug(frame: frame, usingUltraWide: Self.useUltraWideImage && useUltraWide)
            }

        case .ultraWide:
            buffer = wideView.latestPixelBuffer
            pose = wideView.currentPose(viewport: viewport, orientation: orientation)
        }

        guard let pose else { return }
        lastPose = pose

        // El proyector sale del renderer del fondo: mismas matemáticas que la
        // imagen de la cámara, así la ventana no puede "nadar" al moverte.
        if Self.useSceneKitProjector, cameraMode == .arkit, arSession.currentFrame != nil {
            let cameraTransform = pose.transform
            let rightColumn = cameraTransform.columns.0
            let right = simd_float3(rightColumn.x, rightColumn.y, rightColumn.z)

            hostView.worldToScreen = { [weak self] world in
                guard let self else { return WindowHostView.WorldProjection(center: .zero, pointsPerMeter: 0) }
                let scene = self.sceneView
                let point = scene.projectPoint(SCNVector3(x: Float(world.x),
                                                          y: Float(world.y),
                                                          z: Float(world.z)))
                guard point.x.isFinite, point.y.isFinite else {
                    return WindowHostView.WorldProjection(center: .zero, pointsPerMeter: 0)
                }

                let meter = world + right
                let offset = scene.projectPoint(SCNVector3(x: Float(meter.x),
                                                           y: Float(meter.y),
                                                           z: Float(meter.z)))
                let pointsPerMeter = hypot(CGFloat(offset.x - point.x),
                                           CGFloat(offset.y - point.y))
                guard pointsPerMeter.isFinite, pointsPerMeter > 0.1 else {
                    return WindowHostView.WorldProjection(center: .zero, pointsPerMeter: 0)
                }

                return WindowHostView.WorldProjection(center: CGPoint(x: CGFloat(point.x),
                                                                      y: CGFloat(point.y)),
                                                      pointsPerMeter: pointsPerMeter)
            }
        } else {
            hostView.worldToScreen = nil
        }

        hostView.layout(pose: pose)

        if stereoEnabled {
            updateStereoPanes(pose: pose, buffer: buffer)
        }

        // El menú se crea recién cuando ya hay una pose real de ARKit, así su
        // posición queda en el mundo y no en el origen "provisional".
        if menuWindow == nil {
            ensureMenu()
        }

        if occlusionEnabled, let buffer {
            occlusionView.update(buffer: buffer, hands: lastHands, orientation: orientation)
        }

        guard handsVisible, let buffer else { return }
        tracker.submit(pixelBuffer: buffer,
                       viewportSize: viewport,
                       imageAspect: pose.imageAspect,
                       orientation: ScreenOrientation.visionOrientation(for: orientation)) { [weak self] poses in
            DispatchQueue.main.async { self?.apply(poses) }
        }
    }

    /// Solo aceptamos buffers con tamaño y formato razonables.
    private static func isUsable(_ buffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        return width >= 320 && height >= 240 && CVPixelBufferGetPixelFormatType(buffer) != 0
    }

    private func updateDebug(frame: ARFrame, usingUltraWide: Bool) {
        let now = CACurrentMediaTime()
        guard now - lastDebugAt > 0.25 else { return }
        lastDebugAt = now

        let tracking: String
        switch frame.camera.trackingState {
        case .normal: tracking = "OK"
        case .notAvailable: tracking = "SIN TRACKING"
        case .limited(let reason): tracking = "LIMITADO(\(reason))"
        }

        let camera = frame.camera.transform.columns.3
        let menu = menuWindow?.position ?? simd_float3.zero
        let screen = lastPose?.project(menu)?.center ?? .zero
        let text = String(format: "%@ %@ %dfps  c %.2f,%.2f  m %.2f,%.2f  s %.0f,%.0f",
                          usingUltraWide ? "0.5x" : "1x",
                          tracking,
                          Int(smoothedFPS),
                          Double(camera.x), Double(camera.z),
                          Double(menu.x), Double(menu.z),
                          Double(screen.x), Double(screen.y))
        debugText = text
    }

    private func apply(_ poses: [HandPose]) {
        lastHands = poses
        overlay.render(poses: poses)
        if handCount != poses.count { handCount = poses.count }

        hostView.allowsPositionWrites = gestures.isDragging

        if controlMode {
            // Si el dedo está sobre el menú, el gesto es del menú y no del PC.
            if let tip = poses.first.map({ $0.joints[.indexTip] ?? $0.pinchPoint }),
               let target = hostView.window(at: tip),
               target.pressAt != nil {
                overlay.setPointer(nil)
                gestures.update(poses: poses, host: hostView, handDepth: handDepth)
                return
            }
            // La mano es el mouse del PC: no se tocan las ventanas.
            overlay.setPointer(pointer.update(poses: poses, viewport: overlay.bounds.size))
        } else {
            // Sobre el menú, mostramos una retícula para ver dónde apunta el dedo.
            if let tip = poses.first.map({ $0.joints[.indexTip] ?? $0.pinchPoint }),
               let target = hostView.window(at: tip),
               target.pressAt != nil {
                overlay.setPointer(tip)
            } else {
                overlay.setPointer(nil)
            }
            gestures.update(poses: poses, host: hostView, handDepth: handDepth)
        }
    }

    // MARK: - Ventanas

    func addVideoWindow(url: URL?) {
        add(kind: .video(url), width: Config.windowWidth, distance: Config.windowDistance)
    }

    func addWebWindow(url: URL) {
        add(kind: .web(url), width: Config.windowWidth, distance: Config.windowDistance)
    }

    /// Abre la ventana de la pantalla del PC (y empieza a escuchar el stream).
    func addPCWindow(port: UInt16 = Config.streamPort) {
        add(kind: .pcStream(port: port), width: Config.streamWidth, distance: Config.streamDistance)
    }

    private func add(kind: WindowKind, width: CGFloat, distance: Float) {
        let position = positionInFrontOfCamera(index: hostView.windows.count, distance: distance)
        hostView.add(kind: kind, position: position, physicalWidth: width)

        if stereoEnabled {
            addMirrorWindow(kind: kind, position: position, width: width)
        }
    }

    // MARK: - Modo VR (dos pantallas)

    private func applyStereoMode() {
        stereoRoot.isHidden = !stereoEnabled

        let monoViews: [UIView] = [cameraSampleView, sceneView, wideView, hostView, occlusionView, overlay]
        for monoView in monoViews {
            monoView.isHidden = stereoEnabled
        }

        if stereoEnabled {
            buildMirrorWindows()
        } else {
            rightPane.host.removeAll()
            leftPane.overlay.render(poses: [])
            rightPane.overlay.render(poses: [])
            applyModeVisibility()
        }
    }

    private func buildMirrorWindows() {
        leftPane.host.removeAll()
        rightPane.host.removeAll()
        for window in hostView.windows {
            addMirrorWindow(kind: window.kind, position: window.position, width: window.physicalWidth)
        }
    }

    private func addMirrorWindow(kind: WindowKind, position: simd_float3, width: CGFloat) {
        for pane in [leftPane, rightPane] {
            let mirror = pane.host.add(kind: kind, position: position, physicalWidth: width)
            (mirror.view.content as? MenuContentView)?.onAction = { [weak self] action in
                self?.handleMenu(action)
            }
        }
    }

    /// Copia posición/tamaño de las ventanas reales a las de cada ojo.
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

    /// Dibuja la escena en las dos mitades (una por ojo).
    private func updateStereoPanes(pose: CameraPose, buffer: CVPixelBuffer?) {
        let size = containerView.bounds.size
        guard size.width > 1 else { return }

        let half = CGSize(width: size.width / 2, height: size.height)
        leftPane.frame = CGRect(origin: .zero, size: half)
        rightPane.frame = CGRect(x: half.width, y: 0, width: half.width, height: half.height)

        leftPane.layoutScene(containerSize: size, scale: vrScale,
                             eyeShift: -vrSeparation / 2, verticalOffset: vrVertical)
        rightPane.layoutScene(containerSize: size, scale: vrScale,
                              eyeShift: vrSeparation / 2, verticalOffset: vrVertical)

        if let buffer {
            leftPane.background.enqueue(buffer)
            rightPane.background.enqueue(buffer)
        }

        syncMirrorWindows()
        leftPane.host.layout(pose: pose)
        rightPane.host.layout(pose: pose)
        leftPane.render(poses: lastHands)
        rightPane.render(poses: lastHands)
    }

    func closeAllWindows() {
        hostView.removeAll(except: menuWindow)
    }

    func toggleHands() {
        handsVisible.toggle()
        overlay.isHidden = !handsVisible
        if !handsVisible {
            overlay.render(poses: [])
            overlay.setPointer(nil)
            gestures.reset()
            lastHands = []
            occlusionView.clear()
            handCount = 0
        }
    }

    /// Posición nueva delante de la cámara, escalonada para que no se tapen.
    private func positionInFrontOfCamera(index: Int,
                                         distance: Float,
                                         transform override: simd_float4x4? = nil) -> simd_float3 {
        let transform = override
            ?? lastPose?.transform
            ?? arSession.currentFrame?.camera.transform
            ?? matrix_identity_float4x4

        let right = simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let back = simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let origin = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        let column = Float(index % 2) * 0.68 - 0.34
        let row = Float((index / 2) % 3) * 0.4

        return origin + right * column + up * (row - 0.10) - back * distance
    }

    // MARK: - Modo control (mano = mouse del PC)

    func toggleControlMode() {
        controlMode.toggle()
        pointer.setEnabled(controlMode)
        gestures.reset()
        overlay.setPointer(nil)

        hostView.allowsPositionWrites = gestures.isDragging

        if controlMode {
            if let host = pcHost {
                pointer.client.connect(host: host)
            } else {
                requestPCHost()
            }
        }
    }

    /// El stream avisa desde qué IP viene el PC: con eso alcanza para el mouse.
    func pcConnected(host: String) {
        pcHost = host
        pointer.client.connect(host: host)
    }

    private func requestPCHost() {
        promptForText(title: "IP del PC",
                      message: "IP de tu PC en la misma Wi-Fi. En el PC corré pc_input.py (escucha en UDP \(Config.inputPort)).",
                      placeholder: "192.168.0.10",
                      current: pcHost) { [weak self] text in
            guard let self, let host = Self.normalizeHost(text) else { return }
            self.pcConnected(host: host)
        }
    }

    static func normalizeHost(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "udp://", with: "")
        if let colon = value.firstIndex(of: ":") {
            value = String(value[value.startIndex..<colon])
        }
        return value.isEmpty ? nil : value
    }

    // MARK: - Elegir video de la galería

    func pickVideo() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        topViewController()?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let provider = results.first?.itemProvider,
              provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else { return }

        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url else { return }
            // El archivo temporal desaparece al salir del closure: hay que copiarlo.
            let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return }
            DispatchQueue.main.async { self?.addVideoWindow(url: destination) }
        }
    }

    // MARK: - Diálogo de URL

    func openURLPrompt() {
        promptForURL(title: "Abrir ventana", message: "URL de una página web o de un video (HLS/MP4).",
                     current: Config.defaultWebURL) { [weak self] url in
            guard let self else { return }
            if url.pathExtension.lowercased() == "m3u8" || url.pathExtension.lowercased() == "mp4" {
                self.addVideoWindow(url: url)
            } else {
                self.addWebWindow(url: url)
            }
        }
    }

    func promptForURL(title: String, message: String, current: URL?, onAccept: @escaping (URL) -> Void) {
        promptForText(title: title, message: message, placeholder: "https://…",
                      current: current?.absoluteString) { text in
            guard let url = Self.normalize(text) else { return }
            onAccept(url)
        }
    }

    func promptForText(title: String, message: String, placeholder: String,
                       current: String?, onAccept: @escaping (String) -> Void) {
        guard let presenter = topViewController() else { return }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.placeholder = placeholder
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in
            guard let text = alert.textFields?.first?.text else { return }
            onAccept(text)
        })
        presenter.present(alert, animated: true)
    }

    static func normalize(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil { return url }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("file:") {
            return URL(fileURLWithPath: trimmed.replacingOccurrences(of: "file://", with: ""))
        }
        return URL(string: "https://" + trimmed)
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return nil }
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
