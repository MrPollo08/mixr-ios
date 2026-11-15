import ARKit
import CoreVideo
import UIKit

/// Lee la distancia real (metros) al dedo desde el mapa de profundidad del LiDAR.
///
/// `ARFrame.sceneDepth` entrega un `depthMap` Float32 con la distancia de cada
/// píxel. Traducimos el punto de pantalla a ese píxel y devolvemos la distancia.
enum HandDepthSampler {

    static func depth(at point: CGPoint,
                      depthMap: CVPixelBuffer,
                      imageAspect: CGFloat,
                      viewport: CGSize,
                      orientation: UIInterfaceOrientation) -> Float? {
        guard imageAspect > 0.1, viewport.width > 1, viewport.height > 1 else { return nil }

        // 1) pantalla → imagen parada, normalizada (origen abajo-izquierda)
        let scale = max(viewport.width / imageAspect, viewport.height)
        let drawnWidth = imageAspect * scale
        let normalizedX = (point.x - (viewport.width - drawnWidth) / 2) / drawnWidth
        let normalizedY = 1 - (point.y - (viewport.height - scale) / 2) / scale
        guard normalizedX >= 0, normalizedX <= 1,
              normalizedY >= 0, normalizedY <= 1 else { return nil }

        // 2) imagen parada → buffer de cámara (la app es horizontal)
        var bufferX = normalizedX
        var bufferY = normalizedY
        if orientation == .landscapeLeft {
            bufferX = 1 - normalizedX
            bufferY = 1 - normalizedY
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard width > 1, height > 1 else { return nil }

        let x = min(max(Int(bufferX * CGFloat(width)), 0), width - 1)
        let y = min(max(Int((1 - bufferY) * CGFloat(height)), 0), height - 1)

        let pixels = base.advanced(by: y * rowBytes + x * 4)
        let meters = pixels.assumingMemoryBound(to: Float32.self).pointee

        guard meters.isFinite, meters > 0.05, meters < 20 else { return nil }
        return meters
    }
}
