import Foundation
import UIKit
import simd

/// Qué muestra la ventana.
enum WindowKind {
    case video(URL?)
    case web(URL)
    /// Pantalla del PC por streaming (H.264) + mouse virtual.
    case pcStream(port: UInt16)

    var initialURL: URL? {
        switch self {
        case .video(let url): return url
        case .web(let url): return url
        case .pcStream: return nil
        }
    }

    var title: String {
        switch self {
        case .video: return "Video"
        case .web: return "Web"
        case .pcStream: return "Pantalla del PC"
        }
    }

    /// Relación ancho / alto del contenido.
    var aspect: CGFloat {
        switch self {
        case .video: return 16.0 / 9.0
        case .web: return 1.0
        case .pcStream: return 16.0 / 9.0
        }
    }

    /// Solo video y web tienen un enlace editable.
    var showsLinkButton: Bool {
        switch self {
        case .video, .web: return true
        case .pcStream: return false
        }
    }

    func makeContent() -> UIView {
        switch self {
        case .video(let url): return VideoContentView(url: url)
        case .web(let url): return WebContentView(url: url)
        case .pcStream(let port): return StreamContentView(port: port)
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
