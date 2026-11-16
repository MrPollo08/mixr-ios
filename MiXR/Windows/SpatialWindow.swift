import ARKit
import Foundation
import UIKit
import simd

/// Qué muestra la ventana.
enum WindowKind {
    case video(URL?)
    case web(URL)
    /// Pantalla del PC por streaming (H.264) + mouse virtual.
    case pcStream(port: UInt16)
    /// Teclado flotante que escribe en la PC.
    case keyboard

    var initialURL: URL? {
        switch self {
        case .video(let url): return url
        case .web(let url): return url
        case .pcStream, .keyboard: return nil
        }
    }

    var title: String {
        switch self {
        case .video: return "Video"
        case .web: return "Web"
        case .pcStream: return "Pantalla del PC"
        case .keyboard: return "Teclado"
        }
    }

    /// Relación ancho / alto del contenido.
    var aspect: CGFloat {
        switch self {
        case .video: return 16.0 / 9.0
        case .web: return 1.0
        case .pcStream: return 16.0 / 9.0
        case .keyboard: return 1.55
        }
    }

    /// Solo video y web tienen un enlace editable.
    var showsLinkButton: Bool {
        switch self {
        case .video, .web: return true
        case .pcStream, .keyboard: return false
        }
    }

    /// El teclado no se puede cerrar con la ✕ (lo cierra el gesto).
    var showsCloseButton: Bool {
        switch self {
        case .keyboard: return false
        default: return true
        }
    }

    func makeContent() -> UIView {
        switch self {
        case .video(let url): return VideoContentView(url: url)
        case .web(let url): return WebContentView(url: url)
        case .pcStream(let port): return StreamContentView(port: port)
        case .keyboard: return KeyboardContentView()
        }
    }
}

/// Un contenido que puede cambiar de URL en caliente.
protocol URLLoadable: AnyObject {
    func setURL(_ url: URL)
}

/// Una ventana flotante anclada a una posición del mundo real.
final class SpatialWindow {
    let kind: WindowKind
    let view: SpatialWindowView

    /// Posición en el espacio de ARKit (metros, mundo real).
    var position: simd_float3
    /// Ancho físico de la ventana (metros).
    var physicalWidth: CGFloat
    /// Cuántos puntos de pantalla mide 1 metro a la profundidad actual.
    /// Lo recalcula WindowHostView en cada frame.
    var pointsPerMeter: CGFloat = 0
    var currentURL: URL?

    /// Si está "pegada", la ventana se queda delante de la cara (no se ancla
    /// al mundo).
    var pinned = false
    var pinnedDistance: Float = 1.1

    /// Dirección (mundo) a la que mira el panel. Se fija al crearlo.
    var normal = simd_float3(0, 0, 1)
    /// Ancla de ARKit: mantiene la ventana clavada en el mundo real (6DoF).
    var anchor: ARAnchor?
    /// Posición suavizada para dibujar (anti temblor del tracking).
    var smoothedCenter: CGPoint?

    /// Apretar un botón del contenido (en coordenadas del host).
    var pressAt: ((CGPoint) -> Bool)?
    /// El dedo se movió sobre el contenido (nil = no hay dedo cerca). dt en segundos.
    var hoverAt: ((CGPoint?, CGFloat) -> Void)?
    /// Scroll por gesto de pinza mantenida + movimiento (punto del host, delta en puntos).
    var scrollAt: ((CGPoint, CGSize) -> Bool)?
    /// Clic / toque directo sobre el contenido (punto en coordenadas del host).
    var clickAt: ((CGPoint) -> Bool)?

    init(kind: WindowKind, position: simd_float3, physicalWidth: CGFloat, view: SpatialWindowView) {
        self.kind = kind
        self.position = position
        self.physicalWidth = physicalWidth
        self.view = view
        self.currentURL = kind.initialURL
    }

    func updateURL(_ url: URL) {
        currentURL = url
        (view.content as? URLLoadable)?.setURL(url)
    }
}
