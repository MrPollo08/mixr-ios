import AVFoundation
import SceneKit
import simd

/// Fondo 360° de video (equirectangular), estilo Dreamspace.
///
/// Es una esfera invertida con el video como material: se ve desde adentro y
/// sigue a la cámara, así el ambiente queda "pegado" al mundo.
final class SkyboxVideoNode: SCNNode {

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
        sphere.firstMaterial = material

        geometry = sphere
        name = "skyboxVideo"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func follow(_ position: simd_float3) {
        self.position = SCNVector3(position.x, position.y, position.z)
    }
}