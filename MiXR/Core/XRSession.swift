import AVFoundation
import Combine
import CoreVideo
import Foundation
import SwiftUI
import UIKit
import Vision
import simd

/// Dreamspace (versión monitor): un monitor grande de la PC, cámara 0.5x y
/// manos sólo para mover (pinza en el borde) y escalar (dos pinzas).
///
/// Sin ARKit, sin LiDAR, sin tiles: menú táctil y una sola ventana.
final class XRSession: NSObject, ObservableObject {

    // MARK: - Estado para SwiftUI

    @Published var handCount = 0
    @Published var status = "Tocá «Monitor PC» para empezar"
    @Published var localAddress = LocalIP.wifiAddress() ?? "sin Wi-Fi"
    @Published var mouseEnabled = false
    @Published var hasMonitor = false

    // MARK: - Vistas

    let wideView = WideCameraView()
    let hostView = WindowHostView()
    let overlay = HandOverlayView()

    // MARK: - Motor

    private let tracker = HandTracker()
    private let gestures = GestureEngine()
    private let pointer = PointerController()
    private let input = InputClient()
    private let gamepad = GamepadController()

    private var displayLink: CADisplayLink?
    private var isRunning = false
    private var lastPose: CameraPose?
    private var lastHands: [HandPose] = []
    private weak var monitor: SpatialWindow?

    /// Vista que entrega SwiftUI: la cámara abajo y el monitor encima.
    lazy var containerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.clipsToBounds = true

        for subview in [wideView, hostView, overlay] as [UIView] {
            subview.frame = view.bounds
            subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(subview)
        }

        hostView.session = self
        overlay.isUserInteractionEnabled = false
        overlay.showsSkeleton = false        // sin dibujos de la mano
        wideView.isUserInteractionEnabled = false
        return view
    }()

    override init() {
        super.init()
        gamepad.onPrimary = { [weak self] in self?.connectPC() }
        gamepad.onSecondary = { [weak self] in self?.closeWindows() }
    }

    // MARK: - Ciclo de vida

    func start() {
        guard !isRunning else { return }
        isRunning = true
        localAddress = LocalIP.wifiAddress() ?? localAddress
        wideView.start()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link

        if status.isEmpty { status = "Cámara lista" }
    }

    func pause() {
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        wideView.stop()
        gestures.reset()
    }

    // MARK: - Monitor de la PC

    /// Abre el monitor (y el servidor que espera el video del PC).
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
        hasMonitor = true
        // Un monitor grande: más ancho que el panel por defecto.
        window.pinnedDistance = 1.6
        status = "Esperando al PC en \(localAddress):\(Config.streamPort)"
    }

    func closeWindows() {
        hostView.removeAll()
        monitor = nil
        hasMonitor = false
        status = "Monitor cerrado"
    }

    func toggleMouse() {
        mouseEnabled.toggle()
        pointer.setEnabled(mouseEnabled)
        gestures.reset()
        status = mouseEnabled ? "Mouse del PC activo" : "Mouse del PC apagado"
    }

    /// La IP del PC llegó por el stream: conectamos el mouse virtual.
    func pcConnected(host: String) {
        input.connect(host: host)
        status = "PC conectado (\(host))"
    }

    /// El teclado/enlaces no se usan en esta versión, pero la ventana base los
    /// declara: se deja vacío para que compile y no moleste.
    func promptForURL(title: String, message: String, current: URL?, completion: @escaping (URL) -> Void) {}

    // MARK: - Frames

    @objc private func tick() {
        guard isRunning else { return }
        let viewport = containerView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return }

        overlay.render(poses: lastHands)

        guard let buffer = wideView.latestPixelBuffer else { return }

        let orientation = ScreenOrientation.current
        let pose = wideView.currentPose(viewport: viewport, orientation: orientation)
        lastPose = pose

        hostView.layout(pose: pose)
        updateGamepad(pose: pose)

        tracker.submit(pixelBuffer: buffer,
                       viewportSize: viewport,
                       imageAspect: pose.imageAspect,
                       orientation: ScreenOrientation.visionOrientation(for: orientation)) { [weak self] poses in
            DispatchQueue.main.async { self?.apply(poses, pose: pose) }
        }
    }

    private func apply(_ poses: [HandPose], pose: CameraPose) {
        lastHands = poses
        if handCount != poses.count { handCount = poses.count }

        hostView.allowsPositionWrites = true

        if mouseEnabled {
            overlay.setPointer(pointer.update(poses: poses, viewport: containerView.bounds.size))
            return
        }

        gestures.update(poses: poses, host: hostView, pose: pose)

        // Rayito sólo cuando la mano está sobre el monitor.
        if let tip = poses.first.map({ $0.pinchPoint }),
           hostView.window(near: tip) != nil {
            overlay.setPointer(tip)
        } else {
            overlay.setPointer(nil)
        }
    }

    // MARK: - Mando Bluetooth (opcional)

    private func updateGamepad(pose: CameraPose) {
        let axes = gamepad.axes
        guard let monitor,
              abs(axes.x) > 0.01 || abs(axes.y) > 0.01 else { return }

        let step = 1.0 / 60.0
        let speed: CGFloat = 1.0
        let right = pose.transform.columns.0
        let up = pose.transform.columns.1
        let delta = simd_float3(right.x, right.y, right.z) * Float(axes.x * speed * step)
            + simd_float3(up.x, up.y, up.z) * Float(axes.y * speed * step)

        hostView.setPosition(monitor, monitor.position + delta, force: true)
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
