import ARKit
import AVFoundation
import Combine
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import simd

/// Orquesta todo: ARKit (cámara del mundo real + posición en el espacio),
/// tracking de manos con Vision y las ventanas flotantes ancladas al mundo.
final class XRSession: NSObject, ObservableObject, ARSCNViewDelegate, PHPickerViewControllerDelegate {

    // MARK: - Estado que consume SwiftUI

    @Published var handCount = 0
    @Published var windowCount = 0
    @Published var handsVisible = true
    @Published var unsupportedMessage: String?
    /// Modo control: la mano maneja el mouse del PC en vez de mover ventanas.
    @Published var controlMode = false
    /// IP del PC conectado (se detecta sola cuando llega el stream).
    @Published var pcHost: String?

    // MARK: - Vistas de UIKit

    let sceneView = ARSCNView()
    let hostView = WindowHostView()
    let overlay = HandOverlayView()

    private let arSession = ARSession()
    private let tracker = HandTracker()
    private let gestures = GestureEngine()
    let pointer = PointerController()
    private var isRunning = false

    /// Contenedor único que se entrega a SwiftUI.
    lazy var containerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.clipsToBounds = true

        let stack: [UIView] = [sceneView, hostView, overlay]
        for subview in stack {
            subview.frame = view.bounds
            subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(subview)
        }
        overlay.isUserInteractionEnabled = false

        hostView.session = self
        hostView.onCountChanged = { [weak self] count in
            guard let self, self.windowCount != count else { return }
            self.windowCount = count
        }
        return view
    }()

    // MARK: - Ciclo de vida

    func start() {
        guard !isRunning, unsupportedMessage == nil else { return }

        guard ARWorldTrackingConfiguration.isSupported else {
            unsupportedMessage = "Este iPhone no soporta ARKit (hace falta iPhone 6s o posterior)."
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.isLightEstimationEnabled = false
        configuration.environmentTexturing = .none

        sceneView.session = arSession
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = false
        sceneView.antialiasingMode = .none
        sceneView.preferredFramesPerSecond = 60

        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true

        configureAudio()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func pause() {
        guard isRunning else { return }
        arSession.pause()
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

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let viewport = containerView.bounds.size
        guard viewport.width > 1 else { return }

        DispatchQueue.main.async { [weak self] in
            self?.hostView.layout(camera: camera, viewportSize: viewport)
        }

        guard handsVisible else { return }
        let image = frame.capturedImage
        tracker.submit(pixelBuffer: image, viewportSize: viewport) { [weak self] poses in
            DispatchQueue.main.async { self?.apply(poses) }
        }
    }

    private func apply(_ poses: [HandPose]) {
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

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.unsupportedMessage = error.localizedDescription
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // Al volver de una interrupción ARKit reanuda solo.
    }

    // MARK: - Ventanas

    func addVideoWindow(url: URL?) {
        add(kind: .video(url), width: Config.windowWidth)
    }

    func addWebWindow(url: URL) {
        add(kind: .web(url), width: Config.windowWidth)
    }

    /// Abre la ventana de la pantalla del PC (y empieza a escuchar el stream).
    func addPCWindow(port: UInt16 = Config.streamPort) {
        let position = positionInFrontOfCamera(index: hostView.windows.count,
                                               distance: Config.streamDistance)
        hostView.add(kind: .pcStream(port: port), position: position, physicalWidth: Config.streamWidth)
    }

    private func add(kind: WindowKind, width: CGFloat) {
        let position = positionInFrontOfCamera(index: hostView.windows.count,
                                               distance: Config.windowDistance)
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
            gestures.reset()
            handCount = 0
        }
    }

    /// Posición nueva delante de la cámara, escalonada para que no se tapen.
    private func positionInFrontOfCamera(index: Int, distance: Float) -> simd_float3 {
        let transform = arSession.currentFrame?.camera.transform ?? matrix_identity_float4x4
        let right = simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let back = simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let origin = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        let column = Float(index % 2) * 0.62 - 0.31
        let row = Float((index / 2) % 3) * 0.36

        return origin + right * column + up * (row - 0.12) - back * distance
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
