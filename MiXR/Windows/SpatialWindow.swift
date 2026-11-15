import Foundation
import UIKit
import simd

/// Qué muestra la ventana.
enum WindowKind {
    case video(URL?)
    case web(URL)
    /// Pantalla del PC por streaming (H.264) + mouse virtual.
    case pcStream(port: UInt16)
    /// Menú flotante de la app (se aprieta con la pinza).
    case menu
    /// Teclado flotante que escribe en la PC.
    case keyboard

    var initialURL: URL? {
        switch self {
        case .video(let url): return url
        case .web(let url): return url
        case .pcStream, .menu, .keyboard: return nil
        }
    }

    var title: String {
        switch self {
        case .video: return "Video"
        case .web: return "Web"
        case .pcStream: return "Pantalla del PC"
        case .menu: return "MiXR"
        case .keyboard: return "Teclado"
        }
    }

    /// Relación ancho / alto del contenido.
    var aspect: CGFloat {
        switch self {
        case .video: return 16.0 / 9.0
        case .web: return 1.0
        case .pcStream: return 16.0 / 9.0
        case .menu: return 1.30
        case .keyboard: return 1.55
        }
    }

    /// Solo video y web tienen un enlace editable.
    var showsLinkButton: Bool {
        switch self {
        case .video, .web: return true
        case .pcStream, .menu, .keyboard: return false
        }
    }

    /// El menú flota sin panel: sólo los íconos.
    var chromeless: Bool {
        if case .menu = self { return true }
        return false
    }

    /// El menú no se puede cerrar: es la página principal.
    var showsCloseButton: Bool {
        switch self {
        case .menu: return false
        default: return true
        }
    }

    func makeContent() -> UIView {
        switch self {
        case .video(let url): return VideoContentView(url: url)
        case .web(let url): return WebContentView(url: url)
        case .pcStream(let port): return StreamContentView(port: port)
        case .menu: return MenuContentView()
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
    /// al mundo). Es lo opuesto al anclaje y se elige con el tile "Pegar".
    var pinned = false
    var pinnedDistance: Float = 1.1

    /// Si la ventana es un menú: apretar un botón (en coordenadas del host).
    var pressAt: ((CGPoint) -> Bool)?
    /// El dedo se movió sobre el menú (nil = no hay dedo cerca). dt en segundos.
    var hoverAt: ((CGPoint?, CGFloat) -> Void)?

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
