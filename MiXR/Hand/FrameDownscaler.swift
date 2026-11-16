import CoreImage
import CoreVideo
import Foundation
import Metal

/// Reduce la imagen de cámara **antes** de pasarla a los modelos de Vision.
///
/// Se hace en la GPU (Core Image → Metal) y reutiliza un pool de `CVPixelBuffer`,
/// así no hay coerción de memoria por frame. El frame original sigue usándose para
/// el color que se muestra; este buffer pequeño es solo para inferencia.
final class FrameDownscaler {

    private let context: CIContext?
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = nil
        }
    }

    /// Devuelve un buffer BGRA del tamaño pedido (manteniendo la relación de aspecto).
    /// El buffer sale de un pool: no se reserva memoria nueva cada frame.
    func downscale(_ source: CVPixelBuffer, maxDimension: Int = 640) -> CVPixelBuffer? {
        guard let context else { return nil }

        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1.0, Double(maxDimension) / Double(max(sourceWidth, sourceHeight)))
        let targetWidth = max(16, Int((Double(sourceWidth) * scale).rounded()))
        let targetHeight = max(16, Int((Double(sourceHeight) * scale).rounded()))
        let target = CGSize(width: targetWidth, height: targetHeight)

        if pool == nil || poolSize != target {
            guard makePool(target) else { return nil }
        }
        guard let pool else { return nil }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
              let output else { return nil }

        let image = CIImage(cvPixelBuffer: source)
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        // Se escala la imagen explícitamente al tamaño destino y se renderiza su extent.
        // (Pasar otra cosa en `bounds` hace que Core Image **recorte** en vez de reducir.)
        let sx = target.width / extent.width
        let sy = target.height / extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        context.render(scaled,
                       to: output,
                       bounds: scaled.extent,
                       colorSpace: colorSpace)

        return output
    }

    private func makePool(_ size: CGSize) -> Bool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
        guard status == kCVReturnSuccess, let newPool else { return false }

        pool = newPool
        poolSize = size
        return true
    }
}
