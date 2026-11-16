import CoreImage
import CoreVideo
import Metal
import QuartzCore
import UIKit
import Vision
import simd

/// **Mano fantasma**: recorta la mano real de la imagen de cámara y la dibuja
/// translúcida, con contorno blanco y halo, por encima de las ventanas.
///
/// Es el efecto del video de referencia. Todo con frameworks nativos:
///
/// - **Segmentación**: `VNGeneratePersonSegmentationRequest` (modelo de Apple, corre en
///   el Neural Engine). Se ejecuta en su propia cola a ~18 Hz.
/// - **Respaldo geométrico**: si la segmentación falla o llega tarde, se usa la silueta
///   que sale de los 21 puntos de Vision, así la mano **nunca** desaparece.
/// - **Composición**: Core Image sobre Metal (GPU). Brillo elevado, alfa parcial y un
///   borde blanco derivado de la propia máscara (`CIEdges` + blur = halo).
final class HandGhostView: UIView {

    // MARK: - Ajustes visuales (calibrables contra la referencia)

    /// Opacidad de la mano recortada. La referencia está en ~0.6.
    private static let handAlpha: CGFloat = 0.62
    /// Cuánto se aclara la mano respecto de la imagen original.
    private static let brightnessLift: CGFloat = 0.14
    private static let contrastLift: CGFloat = 1.10
    /// Ancho del contorno blanco (en puntos) y difusión del halo.
    private static let contourWidth: CGFloat = 2.6
    private static let contourBlurRadius: CGFloat = 1.5
    private static let contourAlpha: CGFloat = 1.0

    /// El compuesto se calcula a media resolución y la capa lo estira: 4× menos píxeles.
    private static let outputScale: CGFloat = 0.5
    /// La máscara no necesita más resolución que esta.
    private static let maskScale: CGFloat = 0.45
    /// Cadencia máxima de la segmentación (~18 Hz).
    private static let maxSegmentationRate: CFTimeInterval = 0.055
    /// Cadencia máxima de composición.
    private static let maxRenderRate: CFTimeInterval = 1.0 / 30.0

    private let imageLayer = CALayer()
    private let context: CIContext?
    private let segmentationQueue = DispatchQueue(label: "mixr.ghost-segmentation", qos: .userInitiated)
    /// Cola separada: la composición no debe esperar a la segmentación.
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

    override init(frame: CGRect) {
        context = MTLCreateSystemDefaultDevice().map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
        }

        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        // Por encima de las ventanas (z = 100) y por debajo de la malla sintética (z = 1000).
        layer.zPosition = 900

        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear

        // Degradado alfa en el antebrazo: funde la mano con el brazo real.
        let mask = CAGradientLayer()
        mask.type = .axial
        mask.colors = [
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor(white: 1.0, alpha: 0.5).cgColor,
            UIColor.clear.cgColor
        ]
        mask.locations = [0.0, 0.36, 0.74, 1.0]
        mask.frame = bounds
        imageLayer.mask = mask
        wristMask = mask

        layer.addSublayer(imageLayer)

        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    private var wristMask: CAGradientLayer?

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        wristMask?.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Entrada

    func update(buffer: CVPixelBuffer?,
                hands: [HandPose],
                orientation: UIInterfaceOrientation) {
        self.buffer = buffer
        self.hands = hands
        self.orientation = orientation

        updateWristFade(hand: hands.first)

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

    /// Orienta el degradado alfa a lo largo del antebrazo real, así el corte con el
    /// brazo queda siempre perpendicular al brazo y no una banda horizontal fija.
    private func updateWristFade(hand: HandPose?) {
        guard let mask = wristMask else { return }
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)

        guard let hand, let wrist = hand.joints[.wrist] else {
            mask.startPoint = CGPoint(x: 0.5, y: 0.0)
            mask.endPoint = CGPoint(x: 0.5, y: 1.0)
            return
        }

        let scale = min(max(hand.palmScale, 14), 340)
        var dir = hand.forearm.direction2D
        if !dir.x.isFinite || !dir.y.isFinite || (abs(dir.x) + abs(dir.y)) < 0.01 {
            dir = CGPoint(x: 0, y: 1)
        }
        let armLength = max(hypot(hand.forearm.elbow2D.x - wrist.x,
                                  hand.forearm.elbow2D.y - wrist.y), scale * 1.3)

        let from = CGPoint(x: wrist.x - dir.x * (scale * 0.45),
                           y: wrist.y - dir.y * (scale * 0.45))
        let to = CGPoint(x: wrist.x + dir.x * (armLength * 0.92),
                         y: wrist.y + dir.y * (armLength * 0.92))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.startPoint = CGPoint(x: from.x / w, y: from.y / h)
        mask.endPoint = CGPoint(x: to.x / w, y: to.y / h)
        CATransaction.commit()
    }

    func clear() {
        imageLayer.contents = nil
        buffer = nil
        hands = []
        personMask = nil
    }

    /// `true` si hay un compuesto en pantalla (lo usa la sesión para auto-respaldo).
    var hasContent: Bool {
        imageLayer.contents != nil
    }

    /// Pide la máscara de persona a Vision (Neural Engine) sin bloquear.
    private func requestSegmentationIfNeeded(_ buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard !segmentationBusy, now - lastSegmentationAt >= Self.maxSegmentationRate else { return }
        lastSegmentationAt = now
        segmentationBusy = true

        let orientation = self.orientation
        segmentationQueue.async { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async { self.segmentationBusy = false }
            }

            let handler = VNImageRequestHandler(
                cvPixelBuffer: buffer,
                orientation: ScreenOrientation.visionOrientation(for: orientation),
                options: [:]
            )
            do {
                try handler.perform([self.segmentation])
                if let result = self.segmentation.results?.first,
                   let mask = try? result.pixelBuffer {
                    self.personMask = mask
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
        var mask = CIImage.empty()
        var hasMask = false

        if let personMask {
            var person = CIImage(cvPixelBuffer: personMask).oriented(forExifOrientation: exif)
            person = person.transformed(by: CGAffineTransform(translationX: -person.extent.origin.x,
                                                              y: -person.extent.origin.y))
            let filled = aspectFill(person, into: rect)
            // Suavizar el borde del modelo (viene duro a esta resolución).
            mask = filled.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.6])
                .cropped(to: rect)
            hasMask = true
        }

        if let geometric = geometricMask(hands: hands, size: size) {
            let geometricImage = CIImage(cgImage: geometric)
                .transformed(by: CGAffineTransform(scaleX: 1 / Self.maskScale,
                                                   y: 1 / Self.maskScale))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.2])
                .cropped(to: rect)

            if hasMask {
                mask = mask.applyingFilter("CIMaximumComposition", parameters: [
                    kCIInputBackgroundImageKey: geometricImage
                ])
            } else {
                mask = geometricImage
                hasMask = true
            }
        }

        guard hasMask else { return nil }

        // --- Mano recortada, aclarada y semi-transparente ---
        let lifted = framed.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: Self.brightnessLift,
            kCIInputContrastKey: Self.contrastLift,
            kCIInputSaturationKey: 1.0
        ])

        // Alfa parcial multiplicando la máscara: evita problemas de premultiplicado.
        let scaledMask = mask.applyingFilter("CIColorMatrix", parameters: [
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

        // --- Contorno blanco + halo ---
        // Se calcula por morfología: (máscara dilatada − máscara) da una banda de ancho
        // fijo pegada al borde de la silueta. Es determinista, no depende de la pendiente
        // de la máscara (que era el fallo del intento con `CIEdges`: la máscara ya venía
        // desenfocada, los bordes daban ~0 y el contorno quedaba invisible).
        let dilated = mask.applyingFilter("CIMorphologyMaximum", parameters: [
            kCIInputRadiusKey: Self.contourWidth
        ])
        let band = dilated
            .applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: mask])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Self.contourBlurRadius])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: Self.contourAlpha, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
            ])
            .cropped(to: rect)

        let composed = band.composited(over: handCut)

        // --- Salida a media resolución ---
        let output = composed.transformed(by: CGAffineTransform(scaleX: Self.outputScale,
                                                                y: Self.outputScale))
        let outputRect = CGRect(x: 0, y: 0,
                                width: rect.width * Self.outputScale,
                                height: rect.height * Self.outputScale)
        return context.createCGImage(output, from: outputRect)
    }

    /// Recorte "aspect fill" igual que el preview de la cámara.
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

    /// Silueta de respaldo a partir de los 21 puntos (para cuando Vision tarda o falla).
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

        // UIKit tiene el origen arriba; el contexto lo tiene abajo.
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
