import ARKit
import CoreVideo
import Foundation
import ObjectiveC

/// Acceso al frame de la **cámara ultra gran angular** que ARKit captura por
/// dentro para tracking, pero que no expone en su API pública.
///
/// Es API privada: sólo válida para apps sideloadeadas (no pasa App Store).
/// Si el iPhone/iOS no tiene ese buffer, devuelve nil y la app sigue usando la
/// cámara normal sin enterarse.
enum ARFrameUltraWide {

    private static let ivar: Ivar? = class_getInstanceVariable(ARFrame.self, "_capturedUltraWideImage")

    static var isAvailable: Bool { ivar != nil }

    static func pixelBuffer(from frame: ARFrame) -> CVPixelBuffer? {
        guard let ivar else { return nil }

        let base = Unmanaged.passUnretained(frame).toOpaque()
        let pointer = base
            .advanced(by: ivar_getOffset(ivar))
            .assumingMemoryBound(to: CVPixelBuffer?.self)

        return pointer.pointee
    }
}
