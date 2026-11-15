import ARKit
import CoreVideo
import Foundation
import simd

/// Recupera el desplazamiento en **profundidad** usando el mapa del LiDAR.
///
/// Problema: en ambientes con poca textura, ARKit puede quedar en `limited` y
/// entregar sólo rotación (la ventana te sigue al caminar).
///
/// Solución: el LiDAR mide **metros reales** a la superficie que hay enfrente.
/// Se guarda esa distancia al anclar y se compara con la que entrega ARKit.
/// La diferencia es exactamente lo que ARKit no está midiendo, y se aplica como
/// corrección al eje de visión.
///
/// Es una fusión segura: si ARKit ya mide bien, la diferencia es ~0 y no se
/// toca nada.
final class DepthAxisTracker {

    private var referenceDepth: Float?
    private var anchorPosition: simd_float3?
    private var anchorForward: simd_float3?
    private var smoothed: Float = 0

    func reset() {
        referenceDepth = nil
        anchorPosition = nil
        anchorForward = nil
        smoothed = 0
    }

    /// Devuelve cuánto hay que corregir en metros (+ = la cámara debería estar
    /// más atrás). Nil si no hay dato confiable.
    func correction(depthMap: CVPixelBuffer?, cameraTransform: simd_float4x4) -> Float? {
        guard let depthMap, let depth = Self.centerDepth(depthMap) else { return nil }

        let backward = simd_float3(cameraTransform.columns.2.x,
                                   cameraTransform.columns.2.y,
                                   cameraTransform.columns.2.z)
        let forward = -backward
        let position = simd_float3(cameraTransform.columns.3.x,
                                   cameraTransform.columns.3.y,
                                   cameraTransform.columns.3.z)

        guard let reference = referenceDepth,
              let startPosition = anchorPosition,
              let startForward = anchorForward else {
            referenceDepth = depth
            anchorPosition = position
            anchorForward = forward
            return nil
        }

        // Cuánto se alejó según el LiDAR (positivo = más lejos).
        let lidarDelta = depth - reference
        // Cuánto se alejó según ARKit (negativo = se fue para atrás).
        let arkitDelta = simd_dot(position - startPosition, startForward)

        // Si ARKit lo midió bien: lidarDelta ≈ -arkitDelta => corrección ~0.
        let correction = lidarDelta + arkitDelta
        smoothed += (correction - smoothed) * 0.18

        guard abs(smoothed) > 0.04 else { return 0 }
        return min(max(smoothed, -2.0), 2.0)
    }

    /// Profundidad mediana en el centro del cuadro (robusta a un píxel suelto).
    private static func centerDepth(_ map: CVPixelBuffer) -> Float? {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard width > 8, height > 8 else { return nil }

        let centerX = width / 2
        let centerY = height / 2

        var samples: [Float] = []
        samples.reserveCapacity(25)

        for dy in -2...2 {
            for dx in -2...2 {
                let x = centerX + dx
                let y = centerY + dy
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let pixel = base.advanced(by: y * rowBytes + x * 4)
                let meters = pixel.assumingMemoryBound(to: Float32.self).pointee
                if meters.isFinite, meters > 0.05, meters < 20 {
                    samples.append(meters)
                }
            }
        }

        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}
