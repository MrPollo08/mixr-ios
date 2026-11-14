import CoreGraphics
import Foundation
import ImageIO
import UIKit
import simd

/// Todo lo que depende de cómo está rotada la pantalla.
///
/// La app se usa en horizontal (tipo visor), pero soporta las dos orientaciones
/// de paisaje y también vertical por si la agarrás así.
enum ScreenOrientation {

    static var current: UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return active.interfaceOrientation
        }
        return scenes.first?.interfaceOrientation ?? .landscapeRight
    }

    /// Tamaño de la imagen ya "parada" según la orientación (para aspect fill).
    static func displaySize(raw: CGSize, orientation: UIInterfaceOrientation) -> CGSize {
        let width = max(raw.width, 1)
        let height = max(raw.height, 1)
        switch orientation {
        case .portrait, .portraitUpsideDown:
            return CGSize(width: min(width, height), height: max(width, height))
        default:
            return CGSize(width: max(width, height), height: min(width, height))
        }
    }

    static func displayAspect(raw: CGSize, orientation: UIInterfaceOrientation) -> CGFloat {
        let size = displaySize(raw: raw, orientation: orientation)
        return size.width / size.height
    }

    /// Rotación de la pantalla respecto del marco del teléfono en vertical.
    ///
    /// Las columnas son los ejes de la pantalla expresados en el marco del
    /// dispositivo (x derecha, y arriba, z hacia atrás).
    static func screenRotation(for orientation: UIInterfaceOrientation) -> simd_float4x4 {
        switch orientation {
        case .portrait:
            return matrix_identity_float4x4

        case .portraitUpsideDown:
            return rotationZ(.pi)

        case .landscapeRight:
            // Botón de inicio a la izquierda: el auricular queda a la derecha.
            // pantalla_x = +y, pantalla_arriba = -x
            return simd_float4x4(columns: (
                simd_float4(0, 1, 0, 0),
                simd_float4(-1, 0, 0, 0),
                simd_float4(0, 0, 1, 0),
                simd_float4(0, 0, 0, 1)
            ))

        case .landscapeLeft:
            // Botón de inicio a la derecha: pantalla_x = -y, pantalla_arriba = +x
            return simd_float4x4(columns: (
                simd_float4(0, -1, 0, 0),
                simd_float4(1, 0, 0, 0),
                simd_float4(0, 0, 1, 0),
                simd_float4(0, 0, 0, 1)
            ))

        @unknown default:
            return matrix_identity_float4x4
        }
    }

    /// Orientación EXIF que hay que darle a Vision para que los puntos salgan
    /// parados respecto de la pantalla (misma tabla que usa Apple en AVCam).
    static func visionOrientation(for orientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        @unknown default: return .up
        }
    }

    private static func rotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(columns: (
            simd_float4(c, s, 0, 0),
            simd_float4(-s, c, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(0, 0, 0, 1)
        ))
    }
}
