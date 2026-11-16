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

    /// La mano se pinta como **gris oscuro translúcido** con borde fino claro: sobre un
    /// panel negro se lee como una silueta oscura, y sobre el mundo real como un tinte.
    /// Así es la referencia: oscura, no blanca.
    private static let fillStrength: CGFloat = 0.72
    private static let fillRed: CGFloat = 0.30
    private static let fillGreen: CGFloat = 0.30
    private static let fillBlue: CGFloat = 0.33
    /// Opacidad final del recorte.
    private static let handAlpha: CGFloat = 0.92
    /// Contorno fino y suave.
    private static let contourWidth: CGFloat = 1.9
    private static let contourBlurRadius: CGFloat = 2.0
    private static let contourAlpha: CGFloat = 0.9

    private static let outputScale: CGFloat = 0.5
    private static let maskScale: CGFloat = 0.45
    private static let maxSegmentationRate: CFTimeInterval = 1.0 / 30.0
    private static let maxRenderRate: CFTimeInterval = 1.0 / 60.0

    private let imageLayer = CALayer()
    private let context: CIContext?
    private let segmentationQueue = DispatchQueue(label: "mixr.ghost-segmentation", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "mixr.ghost-render", qos: .userInitiated)

    private let segmentation = VNGeneratePersonSegmentationRequest()

    private var buffer: CVPixelBuffer?
    private var hands: [HandPose] = []
    private var orientation: UIInterfaceOrientation = .landscapeRight

    private var personMask: CVPixelBuffer?
    /// Mapa de profundidad del LiDAR: permite recortar la mano de verdad.
    private var depthMap: CVPixelBuffer?
    private var lastSegmentationAt: CFTimeInterval = 0
    private var segmentationBusy = false

    private var lastRenderAt: CFTimeInterval = 0
    private var renderBusy = false

    /// Diagnóstico
    private(set) var segmentationCount = 0
    private(set) var maskSizeText = "-"
    /// Fracción de la máscara que es "persona". Si es ~0, la segmentación no encontró
    /// nada y sólo se está dibujando la silueta geométrica (dedos rígidos, anchos iguales).
    private(set) var maskCoverage: Float = 0
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

        // `.balanced` a 30 Hz: la mitad de retraso que `.accurate` (67 ms → 33 ms) y el
        // borde sigue siendo bueno. El retraso de la máscara era lo que se sentía como
        // "fantasma atrasado".
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
                orientation: UIInterfaceOrientation,
                segmentationBuffer: CVPixelBuffer? = nil,
                depthMap: CVPixelBuffer? = nil) {
        self.buffer = buffer
        self.hands = hands
        self.orientation = orientation
        self.depthMap = depthMap

        // La segmentación usa la imagen reducida (4x menos píxeles) pero el color que
        // se compone es el frame completo, así la mano no pierde nitidez.
        if let source = segmentationBuffer ?? buffer {
            requestSegmentationIfNeeded(source)
        } else {
            personMask = nil
        }

        if hands.isEmpty && personMask == nil && depthMap == nil {
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
                    let buffer = result.pixelBuffer
                    let coverage = Self.coverage(of: buffer)
                    self.personMask = buffer
                    self.segmentationCount += 1
                    let w = CVPixelBufferGetWidth(buffer)
                    let h = CVPixelBufferGetHeight(buffer)
                    let text = "\(w)x\(h)"
                    DispatchQueue.main.async {
                        self.maskCoverage = coverage
                        if self.maskSizeText != text { self.maskSizeText = text }
                    }
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

        // --- Máscara ---
        // Prioridad:
        //  1. Segmentación de persona (si el modelo la encuentra).
        //  2. **Profundidad del LiDAR**: recorta los píxeles que están a la distancia de
        //     la mano. Esto devuelve la mano REAL (con nudillos, piel y contorno exacto),
        //     que es lo único que se parece a la referencia.
        //  3. Silueta geométrica, como último respaldo.
        var mask: CIImage?
        var usingRealPixels = false
        let personIsUsable = personMask != nil && maskCoverage > 0.008
        var regionMask: CIImage?

        if let geometric = geometricMask(hands: hands, size: size) {
            regionMask = CIImage(cgImage: geometric)
                .transformed(by: CGAffineTransform(scaleX: 1 / Self.maskScale,
                                                   y: 1 / Self.maskScale))
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 8])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])
                .cropped(to: rect)
        }

        if let personMask, personIsUsable {
            var person = CIImage(cvPixelBuffer: personMask).oriented(forExifOrientation: exif)
            person = person.transformed(by: CGAffineTransform(translationX: -person.extent.origin.x,
                                                              y: -person.extent.origin.y))
            mask = aspectFill(person, into: rect)
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1.4])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.2])
                .cropped(to: rect)
            usingRealPixels = true
        } else if let depthMask = depthBasedMask(hands: hands,
                                                 orientation: orientation,
                                                 rect: rect,
                                                 region: regionMask) {
            mask = depthMask
            usingRealPixels = true
        } else if let regionMask {
            mask = regionMask
        }

        guard var finalMask = mask else { return nil }

        // --- Degradado alfa a lo largo del antebrazo (en Core Image) ---
        if let hand = hands.first, let wristsMask = forearmFade(hand: hand, size: size) {
            finalMask = finalMask.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: wristsMask
            ])
        }

        let solidMask = finalMask.cropped(to: rect)

        // --- Mano: si la máscara es real (LiDAR/persona) se usan los PÍXELES REALES,
        //     ligeramente aclarados; si es geométrica, un relleno oscuro uniforme. ---
        let light = CIImage(color: CIColor(red: Self.fillRed,
                                           green: Self.fillGreen,
                                           blue: Self.fillBlue,
                                           alpha: Self.fillStrength))
            .cropped(to: rect)
        let tinted = light.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: framed
        ])
        let handFill = usingRealPixels
            ? framed.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.06,
                kCIInputContrastKey: 1.06,
                kCIInputSaturationKey: 0.9
            ])
            : tinted

        // Alfa parcial horneado en la máscara (evita líos de premultiplicado).
        let scaledMask = solidMask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: Self.handAlpha, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: Self.handAlpha, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: Self.handAlpha, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        let handCut = handFill.applyingFilter("CIBlendWithMask", parameters: [
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

    /// Fracción de píxeles "persona" en la máscara, muestreada en una grilla 32×32.
    private static func coverage(of buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 8, height > 8 else { return 0 }

        let stepX = max(width / 32, 1)
        let stepY = max(height / 32, 1)
        var hits = 0
        var total = 0

        for y in stride(from: 0, to: height, by: stepY) {
            let row = base.advanced(by: y * rowBytes)
            for x in stride(from: 0, to: width, by: stepX) {
                let value = row.advanced(by: x).assumingMemoryBound(to: UInt8.self).pointee
                if value > 128 { hits += 1 }
                total += 1
            }
        }

        return total > 0 ? Float(hits) / Float(total) : 0
    }

    /// Máscara por **profundidad del LiDAR**: toma los píxeles que están a la distancia
    /// de la mano (dentro de la región de la silueta). Devuelve la mano real, con sus
    /// nudillos y su contorno exacto — que es lo que hace la app de referencia.
    private func depthBasedMask(hands: [HandPose],
                                orientation: UIInterfaceOrientation,
                                rect: CGRect,
                                region: CIImage?) -> CIImage? {
        guard let depthMap, let hand = hands.first, let region else { return nil }
        let handDepth = hand.depthMeters
        guard handDepth > 0.15, handDepth < 2.0 else { return nil }

        let exif = Int32(ScreenOrientation.visionOrientation(for: orientation).rawValue)
        var depth = CIImage(cvPixelBuffer: depthMap).oriented(forExifOrientation: exif)
        depth = depth.transformed(by: CGAffineTransform(translationX: -depth.extent.origin.x,
                                                        y: -depth.extent.origin.y))
        guard depth.extent.width > 1 else { return nil }
        let framedDepth = aspectFill(depth, into: rect)

        // máscara = clamp((limite - profundidad) / suavidad) → 1 donde está más cerca
        let softness: CGFloat = 0.06
        let limit = CGFloat(handDepth) + 0.14
        let gain = 1.0 / softness
        let bias = limit * gain

        let near = framedDepth.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: -gain, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: -gain, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)
        ]).applyingFilter("CIColorClamp")

        return near
            .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: region])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.4])
            .cropped(to: rect)
    }

    private func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {        let imageWidth = image.extent.width
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
