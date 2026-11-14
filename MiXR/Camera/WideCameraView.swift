import AVFoundation
import CoreMedia
import UIKit
import simd

/// Cámara ultra gran angular (0.5x) con su preview y sus frames para Vision.
///
/// ARKit en iPhone no permite elegir la ultra gran angular, así que este modo
/// usa AVFoundation directo + CoreMotion para la orientación (3DoF). Gana
/// mucho campo de visión, que es lo que hace falta para las manos tipo visor.
final class WideCameraView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "mixr.wide-camera", qos: .userInitiated)
    private let motion = MotionOrientation()
    private let lock = NSLock()

    private var configured = false
    private(set) var imageSize = CGSize(width: 1920, height: 1440)
    private var latest: CVPixelBuffer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = session

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    deinit {
        if session.isRunning { session.stopRunning() }
        motion.stop()
    }

    // MARK: - Preview

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        updatePreviewOrientation()
    }

    private func updatePreviewOrientation() {
        guard let connection = previewLayer.connection, connection.isVideoOrientationSupported else { return }
        let target: AVCaptureVideoOrientation
        switch ScreenOrientation.current {
        case .portrait: target = .portrait
        case .portraitUpsideDown: target = .portraitUpsideDown
        case .landscapeLeft: target = .landscapeLeft
        case .landscapeRight: target = .landscapeRight
        @unknown default: target = .landscapeRight
        }
        if connection.videoOrientation != target {
            connection.videoOrientation = target
        }
    }

    // MARK: - Datos

    var latestPixelBuffer: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func currentPose(viewport: CGSize, orientation: UIInterfaceOrientation) -> CameraPose {
        CameraPose(rotation: motion.rotation,
                   orientation: orientation,
                   viewport: viewport,
                   imageSize: imageSize,
                   longFieldOfView: Config.ultraWideLongFieldOfView * .pi / 180)
    }

    /// Toma la orientación actual como "adelante".
    func recenter() {
        motion.recenter()
    }

    // MARK: - Ciclo de vida

    func start() {
        if !configured {
            configured = configure()
        }
        guard configured else { return }
        motion.start()
        captureQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        motion.stop()
        lock.lock()
        latest = nil
        lock.unlock()
        captureQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Configuración

    private func configure() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device else {
            session.commitConfiguration()
            return false
        }

        if let format = Self.bestFormat(for: device) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format

                let duration = CMTime(value: 1, timescale: Config.wideCameraFPS)
                let supportsFPS = format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameDuration <= duration
                }
                if supportsFPS {
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                }
                device.unlockForConfiguration()

                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                imageSize = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
            } catch {
                // Seguimos con el formato que eligió AVFoundation.
            }
        }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)

        session.commitConfiguration()
        updatePreviewOrientation()
        return true
    }

    /// Formato 4:3 (el más parecido a 1920 de ancho): así no perdemos campo
    /// de visión arriba y abajo, que es donde están las manos.
    private static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0, dimensions.height > 0 else { continue }

            let aspect = CGFloat(dimensions.width) / CGFloat(dimensions.height)
            guard abs(aspect - 4.0 / 3.0) < 0.02 else { continue }

            let score = abs(CGFloat(dimensions.width) - 1920)
            if score < bestScore {
                bestScore = score
                best = format
            }
        }
        return best
    }
}

extension WideCameraView: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = buffer
        lock.unlock()
    }
}
