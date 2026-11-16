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
    /// La pantalla del PC un poco más lejos, como un monitor en el escritorio.
    static let streamDistance: Float = 1.45

    /// Ancho físico por defecto de una ventana (metros).
    static let windowWidth: CGFloat = 0.52
    /// Ancho de la ventana del PC (metros).
    static let streamWidth: CGFloat = 0.62

    /// Límites de tamaño al escalar con las dos manos.
    static let minWindowWidth: CGFloat = 0.22
    static let maxWindowWidth: CGFloat = 1.80

    /// Distancia (metros) a la que se puede empujar/traer una ventana con la mano.
    static let minWindowDistance: CGFloat = 0.45
    static let maxWindowDistance: CGFloat = 6.00
    /// Cuánto se amplifica el empuje de la mano al alejar una ventana
    /// (1 = la ventana se aleja exactamente lo que la mano).
    static let windowDepthGain: CGFloat = 1.8

    /// Rango de profundidad en el que se dibuja una ventana (metros).
    static let minDepth: Float = 0.25
    static let maxDepth: Float = 9.0

    /// Cada cuánto se procesa un frame para las manos.
    static let handTrackingInterval: TimeInterval = 1.0 / 60.0

    /// Puerto TCP donde el iPhone escucha el video del PC.
    static let streamPort: UInt16 = 47295
    /// Puerto UDP donde el PC escucha el mouse virtual.
    static let inputPort: UInt16 = 47300

    /// Campo de visión del lado largo de la cámara ultra gran angular (0.5x).
    /// iPhone: ~105–110°. Se puede subir/bajar si el fondo y las manos no
    /// coinciden exactamente con el mundo real.
    static let ultraWideLongFieldOfView: CGFloat = 106

    /// Cadencia de la cámara gran angular (frames por segundo).
    static let wideCameraFPS: Int32 = 30

    /// Menú flotante: a qué distancia y qué ancho (metros).
    static let menuDistance: Float = 1.10
    static let menuWidth: CGFloat = 1.00

    static let youtubeURL = URL(string: "https://m.youtube.com")!
}

/// Comando que hay que ejecutar en el PC para mandar la pantalla al iPhone.
enum StreamCommand {
    static func ffmpeg(ip: String, port: UInt16) -> String {
        "ffmpeg -f gdigrab -framerate 60 -i desktop "
            + "-vf \"scale=-2:1080\" "
            + "-c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g 60 "
            + "-bsf:v dump_extra -flush_packets 1 "
            + "-f h264 tcp://\(ip):\(port)"
    }
}
