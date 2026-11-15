import ARKit
import Combine
import CoreVideo
import Foundation
import SceneKit
import SwiftUI
import UIKit
import Vision
import simd

/// Dreamspace (monitor): un monitor grande de la PC clavado en el mundo real.
///
/// - ARKit 6DoF (una sola cámara: sin cambios, sin parpadeo).
/// - «Fijar en mesa»: escanea el plano, toma coordenadas del mundo y deja el
///   monitor anclado ahí para siempre (ARAnchor).
/// - Manos: pinza en el borde = mover · dos pinzas = tamaño.
final class XRSession: NSObject, ObservableObject {

    // MARK: - Estado para SwiftUI

    @Published var handCount = 0
    @Published var status = "Tocá «Monitor PC» para empezar"
    @Published var localAddress = LocalIP.wifiAddress() ?? "sin Wi-Fi"
    @Published var mouseEnabled = false

    // MARK: - Vistas

    let sceneView = ARSCNView()
    let hostView = WindowHostView()
    let overlay = HandOverlayView()

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
    private weak var monitor: SpatialWindow?
    private var wasDragging = false
    /// El mando está moviendo el monitor (no se re-ancla en el medio).
    private var gamepadMoving = false

    lazy var containerView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.clipsToBounds = true

        for subview in [sceneView, hostView, overlay] as [UIView] {
            subview.frame = view.bounds
            subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(subview)
        }

        hostView.session = self
        overlay.isUserInteractionEnabled = false
        overlay.showsSkeleton = false
        sceneView.isUserInteractionEnabled = false
        return view
    }()

    override init() {
        super.init()
        gamepad.onPrimary = { [weak self] in self?.connectPC() }
        gamepad.onSecondary = { [weak self] in self?.snapMonitorToSurface() }
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
    }

    private func startARKit() {
        guard ARWorldTrackingConfiguration.isSupported else {
            status = "Este iPhone no soporta ARKit"
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        // Escanear superficies (mesa, piso): de acá salen las coordenadas fijas.
        configuration.planeDetection = [.horizontal]
        configuration.isLightEstimationEnabled = false
        configuration.environmentTexturing = .none

        sceneView.session = arSession
        sceneView.automaticallyUpdatesLighting = false
        sceneView.antialiasingMode = .none

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

    /// Trae el monitor delante de la cámara y lo re-ancla ahí.
    func centerMonitor() {
        guard let monitor else { return }
        hostView.setPosition(monitor, positionInFront(distance: 1.6), force: true)
        monitor.smoothedCenter = nil
        reanchor(monitor)
    }

    /// **Escanea la mesa y fija el monitor ahí**: usa el plano detectado por
    /// ARKit y guarda coordenadas del mundo. Queda clavado para siempre.
    func snapMonitorToSurface() {
        guard let monitor else {
            status = "Primero abrí el monitor (Monitor PC)"
            return
        }

        let viewport = containerView.bounds.size
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        let results = sceneView.hitTest(center,
                                        types: [.existingPlaneUsingExtent,
                                                .existingPlane,
                                                .estimatedHorizontalPlane])
        guard let hit = results.first else {
            status = "No veo la superficie: mové el iPhone unos segundos sobre la mesa"
            return
        }

        let t = hit.worldTransform.columns.3
        // El centro del panel, 30 cm arriba de la mesa (queda apoyado a la vista).
        let base = simd_float3(t.x, t.y, t.z)
        let position = base + simd_float3(0, 0.30, 0)

        // Mira hacia la cámara.
        if let pose = lastPose {
            let c = pose.transform.columns.3
            let camera = simd_float3(c.x, c.y, c.z)
            let direction = camera - position
            let length = simd_length(direction)
            if length > 0.1 {
                monitor.normal = simd_normalize(direction)
            }
        }

        monitor.smoothedCenter = nil
        hostView.setPosition(monitor, position, force: true)
        reanchor(monitor)

        let distance = lastPose?.project(position)?.depth ?? 0
        status = String(format: "Fijado en la mesa (%.1f m). Queda clavado ahí.", distance)
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

    /// ARKit corrige el origen del mundo al re-localizar: el ancla manda, así la
    /// ventana sigue clavada en el lugar real.
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
        let viewport = containerView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return }
        guard let frame = arSession.currentFrame else { return }

        let orientation = ScreenOrientation.current
        let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage),
                               height: CVPixelBufferGetHeight(frame.capturedImage))
        let pose = CameraPose(arkitCamera: frame.camera,
                              orientation: orientation,
                              viewport: viewport,
                              imageSize: imageSize)
        lastPose = pose

        overlay.render(poses: lastHands)
        hostView.layout(pose: pose)
        updateGamepad(pose: pose)

        tracker.submit(pixelBuffer: frame.capturedImage,
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

        // Al soltar, el ancla se muda a donde quedó: no se mueve más.
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

    // MARK: - Utilidades

    private func positionInFront(distance: Float) -> simd_float3 {
        guard let pose = lastPose else { return simd_float3(0, 0, -distance) }
        let columns = pose.transform.columns
        let forward = simd_float3(-columns.2.x, -columns.2.y, -columns.2.z)
        let position = simd_float3(columns.3.x, columns.3.y, columns.3.z)
        return position + forward * distance
    }
}
