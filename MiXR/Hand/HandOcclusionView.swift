import CoreImage
import CoreVideo
import Metal
import UIKit
import Vision

/// Hace que las manos **pasen por delante** de las ventanas.
///
/// Recorta la imagen de la cámara con la silueta de la mano (dedos + palma) y
/// la dibuja encima de las ventanas. Como usa los píxeles reales de la cámara,
/// se ve la mano de verdad y no un dibujo.
final class HandOcclusionView: UIView {

    private let imageLayer = CALayer()
    private let context: CIContext?
    private let queue = DispatchQueue(label: "mixr.occlusion", qos: .userInitiated)

    private var buffer: CVPixelBuffer?
    private var hands: [HandPose] = []
    private var orientation: UIInterfaceOrientation = .landscapeRight
    private var busy = false

    /// La máscara se dibuja a media resolución (más rápido) y después se
    /// reescala para que coincida con la imagen de la cámara.
    private static let maskScale: CGFloat = 0.5

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
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = bounds
    }

    // MARK: - Entrada

    func update(buffer: CVPixelBuffer?,
                hands: [HandPose],
                orientation: UIInterfaceOrientation) {
        self.buffer = buffer
        self.hands = hands
        self.orientation = orientation
        schedule()
    }

    func clear() {
        imageLayer.contents = nil
        buffer = nil
        hands = []
    }

    // MARK: - Render (fuera del hilo principal)

    private func schedule() {
        guard context != nil, !busy else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }

        guard let buffer, !hands.isEmpty else {
            imageLayer.contents = nil
            return
        }

        busy = true
        let hands = self.hands
        let orientation = self.orientation
        let size = bounds.size

        queue.async { [weak self] in
            guard let self else { return }
            let image = self.compose(buffer: buffer, hands: hands, orientation: orientation, size: size)
            DispatchQueue.main.async {
                if let image {
                    self.imageLayer.contents = image
                } else {
                    self.imageLayer.contents = nil
                }
                self.busy = false
            }
        }
    }

    private func compose(buffer: CVPixelBuffer,
                         hands: [HandPose],
                         orientation: UIInterfaceOrientation,
                         size: CGSize) -> CGImage? {
        guard let context else { return nil }

        let exif = Int32(ScreenOrientation.visionOrientation(for: orientation).rawValue)
        var source = CIImage(cvPixelBuffer: buffer).oriented(forExifOrientation: exif)
        source = source.transformed(by: CGAffineTransform(translationX: -source.extent.origin.x,
                                                          y: -source.extent.origin.y))

        let imageWidth = source.extent.width
        let imageHeight = source.extent.height
        guard imageWidth > 1, imageHeight > 1 else { return nil }

        // Mismo recorte "aspect fill" que el preview de la cámara.
        let fill = max(size.width / imageWidth, size.height / imageHeight)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let dx = (size.width - imageWidth * fill) / 2
        let dy = (size.height - imageHeight * fill) / 2
        let rect = CGRect(origin: .zero, size: size)

        let framed = scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: rect)

        guard let mask = makeMask(hands: hands, size: size) else { return nil }

        let maskImage = CIImage(cgImage: mask)
            .transformed(by: CGAffineTransform(scaleX: 1 / Self.maskScale,
                                               y: 1 / Self.maskScale))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4])
            .cropped(to: rect)

        let clear = CIImage(color: CIColor.clear).cropped(to: rect)
        let blended = framed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: maskImage,
            kCIInputBackgroundImageKey: clear
        ])

        return context.createCGImage(blended, from: rect)
    }

    // MARK: - Máscara de la mano

    private func makeMask(hands: [HandPose], size: CGSize) -> CGImage? {
        let width = Int(size.width * Self.maskScale)
        let height = Int(size.height * Self.maskScale)
        guard width > 1, height > 1 else { return nil }

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // A partir de acá dibujamos en puntos de pantalla, con el origen arriba
        // a la izquierda (como UIKit).
        ctx.scaleBy(x: Self.maskScale, y: Self.maskScale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for hand in hands {
            draw(hand, in: ctx)
        }

        return ctx.makeImage()
    }

    private func draw(_ hand: HandPose, in ctx: CGContext) {
        let points = hand.joints
        guard let wrist = points[.wrist], let middle = points[.middleMCP] else { return }

        let handSize = hypot(wrist.x - middle.x, wrist.y - middle.y)
        guard handSize > 6 else { return }

        // Palma: el polígono de la base de los dedos, bien grueso.
        let palmNames: [VNHumanHandPoseObservation.JointName] = [
            .wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP
        ]
        let palmPoints = palmNames.compactMap { points[$0] }
        if palmPoints.count >= 3 {
            ctx.setLineWidth(handSize * 0.62)
            let path = CGMutablePath()
            path.addLines(between: palmPoints)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.strokePath()
        }

        // Dedos: cada cadena, con un ancho proporcional a la mano.
        ctx.setLineWidth(handSize * 0.26)
        for chain in HandTracker.connections {
            let chainPoints = chain.compactMap { points[$0] }
            guard chainPoints.count >= 2 else { continue }
            let path = CGMutablePath()
            path.addLines(between: chainPoints)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }
}
