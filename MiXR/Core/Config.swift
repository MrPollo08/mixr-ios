import Foundation
import CoreGraphics

/// Constantes de la app. Todo en metros (mundo real) salvo lo que dice "pt".
enum Config {
    /// Stream HLS de ejemplo de Apple: funciona sin configurar nada.
    static let sampleVideoURL = URL(string:
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!

    static let defaultWebURL = URL(string: "https://www.apple.com")!

    /// Distancia a la que aparecen las ventanas nuevas (metros).
    static let windowDistance: Float = 1.25

    /// Ancho físico por defecto de una ventana (metros).
    static let windowWidth: CGFloat = 0.52

    /// Límites de tamaño al escalar con las dos manos.
    static let minWindowWidth: CGFloat = 0.22
    static let maxWindowWidth: CGFloat = 1.80

    /// Rango de profundidad en el que se dibuja una ventana (metros).
    static let minDepth: Float = 0.25
    static let maxDepth: Float = 9.0

    /// Cada cuántos milisegundos se procesa un frame para las manos.
    static let handTrackingInterval: TimeInterval = 1.0 / 24.0
}
