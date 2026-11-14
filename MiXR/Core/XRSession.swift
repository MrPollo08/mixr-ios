import ARKit
import AVFoundation
import Combine
import CoreVideo
import PhotosUI
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
    @Published private(set) var occlusionEnabled = true

    private static let modeKey = "mixr.cameraMode"

    /// Arranca en 1× (ARKit 6DoF): así las ventanas quedan clavadas en el
    /// mundo y no te siguen. 0.5× da más campo pero es solo rotación.
    private static func savedMode() -> CameraMode {
        switch UserDefaults.standard.string(forKey: modeKey) {
        case "ultraWide": return .ultraWide
        case "arkit": return .arkit
        default: return .arkit
        }
    }

    private func saveMode() {
        UserDefaults.standard.set(cameraMode == .arkit ? "arkit" : "ultraWide", forKey: Self.modeKey)
    }

    // MARK: - Vistas de UIKit

    let sceneView = ARSCNView()
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

    /// Contenedor único que se entrega a SwiftUI.
    lazy var containerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.clipsToBounds = true

        // De abajo a arriba: cámara, ventanas, manos (oclusión), esqueleto.
        let stack: [UIView] = [sceneView, wideView, hostView, occlusionView, overlay]
        for subview in stack {
            subview.frame = view.bounds
            subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(subview)
        }

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
        return view
    }()

    // MARK: - Ciclo de vida

    func start() {
        guard !isRunning else { return }

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
            configuration.planeDetection = []
            configuration.isLightEstimationEnabled = false
            configuration.environmentTexturing = .none

            sceneView.session = arSession
            sceneView.automaticallyUpdatesLighting = false
            sceneView.antialiasingMode = .none
            sceneView.preferredFramesPerSecond = 60
            arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            wideView.stop()

        case .ultraWide:
            arSession.pause()
            wideView.start()
        }

        applyModeVisibility()

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
        sceneView.isHidden = cameraMode != .arkit
        wideView.isHidden = cameraMode != .ultraWide
        occlusionView.isHidden = !occlusionEnabled
        if occlusionView.isHidden { occlusionView.clear() }
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

    /// Toma la orientación actual como "adelante" (solo modo gran angular).
    func recenterView() {
        wideView.recenter()
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
                let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage),
                                       height: CVPixelBufferGetHeight(frame.capturedImage))
                pose = CameraPose(arkitCamera: frame.camera,
                                  orientation: orientation,
                                  viewport: viewport,
                                  imageSize: imageSize)
                buffer = frame.capturedImage
            }

        case .ultraWide:
            buffer = wideView.latestPixelBuffer
            pose = wideView.currentPose(viewport: viewport, orientation: orientation)
        }

        guard let pose else { return }
        lastPose = pose
        hostView.layout(pose: pose)

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

    private func apply(_ poses: [HandPose]) {
        lastHands = poses
        overlay.render(poses: poses)
        if handCount != poses.count { handCount = poses.count }

        if controlMode {
            // La mano es el mouse del PC: no se tocan las ventanas.
            overlay.setPointer(pointer.update(poses: poses, viewport: overlay.bounds.size))
        } else {
            overlay.setPointer(nil)
            gestures.update(poses: poses, host: hostView)
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
    }

    func closeAllWindows() {
        hostView.removeAll()
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
    private func positionInFrontOfCamera(index: Int, distance: Float) -> simd_float3 {
        let transform = lastPose?.transform
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
