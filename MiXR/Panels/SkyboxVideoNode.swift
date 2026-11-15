import AVFoundation
import SceneKit
import simd

/// Fondo 360° de video (equirectangular), estilo Dreamspace.
///
/// Es una esfera invertida con el video como material: se ve desde adentro y
/// sigue a la cámara, así el ambiente queda "pegado" al mundo.
final class SkyboxVideoNode: SCNNode {

    /// Cuánto se corre la textura para llevar el horizonte del video al medio
    /// de la esfera. 0.5 - 0.29 (el horizonte está al 29 % de la altura).
    static let horizonOffset: Float = 0.21

    private let player = AVPlayer()

    init(url: URL) {
        super.init()

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.play()

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: item, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }

        let sphere = SCNSphere(radius: 12)
        sphere.segmentCount = 96

        let material = SCNMaterial()
        material.diffuse.contents = player
        material.lightingModel = .constant
        material.cullMode = .front
        material.isDoubleSided = true

        // El video trae el horizonte a ~29 % de la altura (no al medio, como un
        // equirectangular prolijo). Sin corregirlo, el horizonte queda 38° por
        // encima de la línea de los ojos y sólo se ve mar. Se sube la textura
        // para que el horizonte caiga justo en el ecuador de la esfera.
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        material.diffuse.contentsTransform = SCNMatrix4MakeTranslation(0, Self.horizonOffset, 0)

        sphere.firstMaterial = material

        geometry = sphere
        name = "skyboxVideo"
        // Después de la malla de oclusión (orden -1000): así la cama y la pared
        // tapan la tormenta en vez de quedar detrás.
        renderingOrder = 10
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func follow(_ position: simd_float3) {
        self.position = SCNVector3(position.x, position.y, position.z)
    }
}