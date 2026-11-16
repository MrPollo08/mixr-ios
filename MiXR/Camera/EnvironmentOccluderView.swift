import CoreImage
import CoreVideo
import Metal
import QuartzCore
import UIKit

/// **Oclusión por el entorno real.**
///
/// Devuelve, por encima de los paneles, los píxeles de cámara que están **más cerca que
/// el panel**. Así una silla, la mesa, tu brazo o una persona que pase por delante
/// **tapan la pantalla**, en vez de que la pantalla se dibuje siempre encima.
///
/// Usa el `depthMap` del LiDAR (`smoothedSceneDepth`) y composición Core Image en GPU.
/// Es el efecto que hace que las ventanas se sientan objetos de la habitación.
final class EnvironmentOccluderView: UIView {

    /// Ancho de la transición de profundidad, en metros (borde suave, no dientes de sierra).
    private static let softness: CGFloat = 0.06
    private static let outputScale: CGFloat = 0.85
    private static let maxRenderRate: CFTimeInterval = 1.0 / 30.0

    private let imageLayer = CALayer()
    private let context: CIContext?
    private let renderQueue = DispatchQueue(label: "mixr.environment-occluder", qos: .userInitiated)

    private var buffer: CVPixelBuffer?
    private var depthMap: CVPixelBuffer?
    private var threshold: Float?
    private var orientation: UIInterfaceOrientation = .landscapeRight

    private var lastRenderAt: CFTimeInterval = 0
    private var renderBusy = false

    override init(frame: CGRect) {
        context = MTLCreateSystemDefaultDevice().map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
        }

        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false

        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    /// `threshold`: profundidad del panel más cercano. `nil` = no hay paneles, no ocluir.
    func update(buffer: CVPixelBuffer?,
                depthMap: CVPixelBuffer?,
                threshold: Float?,
                orientation: UIInterfaceOrientation) {
        self.buffer = buffer
        self.depthMap = depthMap
        self.threshold = threshold
        self.orientation = orientation

        guard let threshold, threshold > 0.2, buffer != nil, depthMap != nil else {
            if imageLayer.contents != nil { imageLayer.contents = nil }
            return
        }

        schedule()
    }

    func clear() {
        imageLayer.contents = nil
        buffer = nil
        depthMap = nil
        threshold = nil
    }

    private func schedule() {
        guard context != nil, !renderBusy else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }

        let now = CACurrentMediaTime()
        guard now - lastRenderAt >= Self.maxRenderRate else { return }
        guard let buffer, let depthMap, let threshold else { return }

        lastRenderAt = now
        renderBusy = true

        let orientation = self.orientation
        let size = bounds.size

        renderQueue.async { [weak self] in
            guard let self else { return }
            let image = self.compose(buffer: buffer,
                                     depthMap: depthMap,
                                     threshold: threshold,
                                     orientation: orientation,
                                     size: size)
            DispatchQueue.main.async {
                self.imageLayer.contents = image
                self.renderBusy = false
            }
        }
    }

    private func compose(buffer: CVPixelBuffer,
                         depthMap: CVPixelBuffer,
                         threshold: Float,
                         orientation: UIInterfaceOrientation,
                         size: CGSize) -> CGImage? {
        guard let context else { return nil }

        let exif = Int32(ScreenOrientation.visionOrientation(for: orientation).rawValue)
        let rect = CGRect(origin: .zero, size: size)

        var source = CIImage(cvPixelBuffer: buffer).oriented(forExifOrientation: exif)
        source = source.transformed(by: CGAffineTransform(translationX: -source.extent.origin.x,
                                                          y: -source.extent.origin.y))
        guard source.extent.width > 1 else { return nil }

        let framed = aspectFill(source, into: rect)

        var depth = CIImage(cvPixelBuffer: depthMap).oriented(forExifOrientation: exif)
        depth = depth.transformed(by: CGAffineTransform(translationX: -depth.extent.origin.x,
                                                        y: -depth.extent.origin.y))
        guard depth.extent.width > 1 else { return nil }
        let depthFramed = aspectFill(depth, into: rect)

        // máscara = clamp((threshold - depth) / softness, 0, 1)
        // → 1 donde el mundo está claramente más cerca que el panel.
        let scale = Float(1.0 / Self.softness)
        let bias = Float(threshold) * scale
        let unclamped = depthFramed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(-scale), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: CGFloat(-scale), y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: CGFloat(-scale), y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 1)
        ])

        let mask = unclamped
            .applyingFilter("CIColorClamp")
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5.0])
            .cropped(to: rect)

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        let cut = framed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: clear
        ])

        let output = cut.transformed(by: CGAffineTransform(scaleX: Self.outputScale,
                                                           y: Self.outputScale))
        let outputRect = CGRect(x: 0, y: 0,
                                width: rect.width * Self.outputScale,
                                height: rect.height * Self.outputScale)
        return context.createCGImage(output, from: outputRect)
    }

    private func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let imageWidth = image.extent.width
        let imageHeight = image.extent.height
        guard imageWidth > 1, imageHeight > 1 else { return image }

        let fill = max(rect.width / imageWidth, rect.height / imageHeight)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let dx = (rect.width - imageWidth * fill) / 2
        let dy = (rect.height - imageHeight * fill) / 2
        return scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: rect)
    }
}
