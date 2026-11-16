import CoreImage
import CoreVideo
import Metal
import QuartzCore
import UIKit
import Vision
import simd

/// **Mano fantasma ("ghost hands")**: recorta la mano real de la imagen de cámara y la
/// dibuja translúcida, con contorno blanco y halo, por encima de las ventanas.
///
/// Todo con frameworks nativos:
/// - `VNGeneratePersonSegmentationRequest` (modelo de Apple, Neural Engine).
/// - Respaldo geométrico con los 21 puntos de `VNDetectHumanHandPoseRequest`.
/// - Composición Core Image / Metal.
///
/// El degradado del antebrazo se hace **dentro de Core Image** (gradiente × máscara),
/// no con un `CAGradientLayer` de máscara: así no hay forma de que la capa quede
/// invisible por un fallo del layer.
final class HandGhostView: UIView {

    // MARK: - Ajustes visuales (calibrables contra la referencia)

    /// Opacidad de la mano recortada.
    static let handAlpha: CGFloat = 0.55
    private static let brightnessLift: CGFloat = 0.14
    private static let contrastLift: CGFloat = 1.10
    /// Ancho del contorno blanco (en puntos) y difusión del halo.
    private static let contourWidth: CGFloat = 2.6
    private static let contourBlurRadius: CGFloat = 1.5

    private static let outputScale: CGFloat = 0.5
    private static let maskScale: CGFloat = 0.45
    private static let maxSegmentationRate: CFTimeInterval = 0.055
    private static let maxRenderRate: CFTimeInterval = 1.0 / 30.0

    private let imageLayer = CALayer()
    private let context: CIContext?
    private let segmentationQueue = DispatchQueue(label: "mixr.ghost-segmentation", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "mixr.ghost-render", qos: .userInitiated)

    private let segmentation = VNGeneratePersonSegmentationRequest()

    private var buffer: CVPixelBuffer?
    private var hands: [HandPose] = []
    private var orientation: UIInterfaceOrientation = .landscapeRight

    private var personMask: CVPixelBuffer?
    private var lastSegmentationAt: CFTimeInterval = 0
    private var segmentationBusy = false

    private var lastRenderAt: CFTimeInterval = 0
    private var renderBusy = false

    /// Diagnóstico
    private(set) var segmentationCount = 0
    var hasMask: Bool { personMask != nil }
    var hasContent: Bool { imageLayer.contents != nil }

    override init(frame: CGRect) {
        context = MTLCreateSystemDefaultDevice().map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
        }

        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        layer.zPosition = 900

        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        layer.addSublayer(imageLayer)

        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
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

    // MARK: - Entrada

    func update(buffer: CVPixelBuffer?,
                hands: [HandPose],
                orientation: UIInterfaceOrientation) {
        self.buffer = buffer
        self.hands = hands
        self.orientation = orientation

        if let buffer {
            requestSegmentationIfNeeded(buffer)
        } else {
            personMask = nil
        }

        if hands.isEmpty && personMask == nil {
            imageLayer.contents = nil
            return
        }

        schedule()
    }

    func clear() {
        imageLayer.contents = nil
        buffer = nil
        hands = []
        personMask = nil
    }

    private func requestSegmentationIfNeeded(_ buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard !segmentationBusy, now - lastSegmentationAt >= Self.maxSegmentationRate else { return }
        lastSegmentationAt = now
        segmentationBusy = true

        let orientation = self.orientation
        segmentationQueue.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.segmentationBusy = false } }

            let handler = VNImageRequestHandler(
                cvPixelBuffer: buffer,
                orientation: ScreenOrientation.visionOrientation(for: orientation),
                options: [:]
            )
            do {
                try handler.perform([self.segmentation])
                if let result = self.segmentation.results?.first {
                    self.personMask = result.pixelBuffer
                    self.segmentationCount += 1
                }
            } catch {
                self.personMask = nil
            }
        }
    }

    // MARK: - Composición

    private func schedule() {
        guard context != nil, !renderBusy else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }

        let now = CACurrentMediaTime()
        guard now - lastRenderAt >= Self.maxRenderRate else { return }
        guard let buffer else { return }

        lastRenderAt = now
        renderBusy = true

        let hands = self.hands
        let orientation = self.orientation
        let size = bounds.size
        let personMask = self.personMask

        renderQueue.async { [weak self] in
            guard let self else { return }
            let image = self.compose(buffer: buffer,
                                     hands: hands,
                                     personMask: personMask,
                                     orientation: orientation,
                                     size: size)
            DispatchQueue.main.async {
                self.imageLayer.contents = image
                self.renderBusy = false
            }
        }
    }

    private func compose(buffer: CVPixelBuffer,
                         hands: [HandPose],
                         personMask: CVPixelBuffer?,
                         orientation: UIInterfaceOrientation,
                         size: CGSize) -> CGImage? {
        guard let context else { return nil }

        let exif = Int32(ScreenOrientation.visionOrientation(for: orientation).rawValue)
        let rect = CGRect(origin: .zero, size: size)

        var source = CIImage(cvPixelBuffer: buffer).oriented(forExifOrientation: exif)
        source = source.transformed(by: CGAffineTransform(translationX: -source.extent.origin.x,
                                                          y: -source.extent.origin.y))
        guard source.extent.width > 1, source.extent.height > 1 else { return nil }

        let framed = aspectFill(source, into: rect)

        // --- Máscara: segmentación de persona ∪ silueta geométrica ---
        var mask: CIImage?
        var personMaskImage: CIImage?

        if let personMask {
            var person = CIImage(cvPixelBuffer: personMask).oriented(forExifOrientation: exif)
            person = person.transformed(by: CGAffineTransform(translationX: -person.extent.origin.x,
                                                              y: -person.extent.origin.y))
            personMaskImage = aspectFill(person, into: rect)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
                .cropped(to: rect)
            mask = personMaskImage
        }

        if let geometric = geometricMask(hands: hands, size: size) {
            let geometricImage = CIImage(cgImage: geometric)
                .transformed(by: CGAffineTransform(scaleX: 1 / Self.maskScale,
                                                   y: 1 / Self.maskScale))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0])
                .cropped(to: rect)

            if let current = mask {
                mask = current.applyingFilter("CIMaximumComposition", parameters: [
                    kCIInputBackgroundImageKey: geometricImage
                ])
            } else {
                mask = geometricImage
            }
        }

        guard var finalMask = mask else { return nil }

        // --- Degradado alfa a lo largo del antebrazo (en Core Image) ---
        if let hand = hands.first, let wristsMask = forearmFade(hand: hand, size: size) {
            finalMask = finalMask.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: wristsMask
            ])
        }

        let solidMask = finalMask.cropped(to: rect)

        // --- Mano recortada, aclarada y semi-transparente ---
        let lifted = framed.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: Self.brightnessLift,
            kCIInputContrastKey: Self.contrastLift,
            kCIInputSaturationKey: 1.0
        ])

        // Alfa parcial horneado en la máscara (evita líos de premultiplicado).
        let scaledMask = solidMask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: Self.handAlpha, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: Self.handAlpha, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: Self.handAlpha, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        let handCut = lifted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: scaledMask,
            kCIInputBackgroundImageKey: clear
        ])

        // --- Contorno blanco + halo por morfología (dilatada − máscara) ---
        let dilated = solidMask.applyingFilter("CIMorphologyMaximum", parameters: [
            kCIInputRadiusKey: Self.contourWidth
        ])
        let band = dilated
            .applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: solidMask])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Self.contourBlurRadius])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
            ])
            .cropped(to: rect)

        let composed = band.composited(over: handCut)

        let output = composed.transformed(by: CGAffineTransform(scaleX: Self.outputScale,
                                                                y: Self.outputScale))
        let outputRect = CGRect(x: 0, y: 0,
                                width: rect.width * Self.outputScale,
                                height: rect.height * Self.outputScale)
        return context.createCGImage(output, from: outputRect)
    }

    /// Gradiente axial blanco → negro a lo largo del antebrazo. Multiplicado por la
    /// máscara deja la mano opaca y desvanece el brazo.
    private func forearmFade(hand: HandPose, size: CGSize) -> CIImage? {
        guard let wrist = hand.joints[.wrist] else { return nil }

        let scale = min(max(hand.palmScale, 14), 340)
        var dir = hand.forearm.direction2D
        if !dir.x.isFinite || !dir.y.isFinite || (abs(dir.x) + abs(dir.y)) < 0.01 {
            dir = CGPoint(x: 0, y: 1)
        }
        let armLength = max(hypot(hand.forearm.elbow2D.x - wrist.x,
                                  hand.forearm.elbow2D.y - wrist.y), scale * 1.3)

        let from = CGPoint(x: wrist.x - dir.x * (scale * 0.45),
                           y: wrist.y - dir.y * (scale * 0.45))
        let to = CGPoint(x: wrist.x + dir.x * (armLength * 0.95),
                         y: wrist.y + dir.y * (armLength * 0.95))

        // CIImage usa origen abajo-izquierda.
        let p0 = CGPoint(x: from.x, y: size.height - from.y)
        let p1 = CGPoint(x: to.x, y: size.height - to.y)

        let filter = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: p0.x, y: p0.y),
            "inputPoint1": CIVector(x: p1.x, y: p1.y),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        ])
        return filter?.outputImage?.cropped(to: CGRect(origin: .zero, size: size))
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

    private func geometricMask(hands: [HandPose], size: CGSize) -> CGImage? {
        guard !hands.isEmpty else { return nil }

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

        ctx.scaleBy(x: Self.maskScale, y: Self.maskScale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)

        for hand in hands {
            guard let path = HandOverlayView.silhouettePath(for: hand) else { continue }
            ctx.addPath(path)
            ctx.fillPath()
        }

        return ctx.makeImage()
    }
}
