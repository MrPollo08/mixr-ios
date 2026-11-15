import RealityKit
import UIKit

/// Cielo virtual del efecto Dreamspace.
///
/// RealityKit puede usar un `EnvironmentResource` como fondo de la escena, pero
/// generarlo desde una imagen en runtime depende de APIs que fueron cambiando
/// entre versiones del SDK. Acá el cielo es una **entidad** (esfera vista desde
/// adentro), así que:
///
/// - compila igual en todo iOS 16+;
/// - se comporta como cualquier objeto de la escena (se oculta, se reemplaza
///   por un modelo, se le cambia la textura);
/// - la malla real del LiDAR lo tapa, que es justo el efecto buscado.
class SkyboxEntity: Entity {

    /// Radio de la esfera, en metros. Queda más cerca que las paredes de una
    /// habitación típica para que el cielo se vea de verdad estando adentro;
    /// los objetos reales lo siguen tapando gracias a la oclusión.
    static let defaultRadius: Float = 8

    init(radius: Float) {
        super.init()
        build(radius: radius)
    }

    /// RealityKit exige el init sin argumentos (`Entity.init()` es `required`).
    required init() {
        super.init()
        build(radius: SkyboxEntity.defaultRadius)
    }

    private func build(radius: Float) {
        name = "skybox"

        let mesh = MeshResource.generateSphere(radius: radius)

        var material = UnlitMaterial()
        if let texture = SkyboxEntity.makeTexture() {
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            // Sin textura igual hay cielo: un azul plano.
            material.color = .init(tint: UIColor(red: 0.16, green: 0.20, blue: 0.38, alpha: 1),
                                   texture: nil)
        }
        // La esfera se mira desde adentro: no descartamos caras.
        material.faceCulling = .none

        addChild(ModelEntity(mesh: mesh, materials: [material]))
    }

    // MARK: - Textura de prueba

    /// Gradiente equirectangular (2:1) generado en runtime: cénit oscuro,
    /// horizonte claro y suelo casi negro. Al ser casi simétrico, se ve bien
    /// aunque la esfera mapee la imagen al revés.
    private static func makeTexture() -> TextureResource? {
        guard let image = makeImage() else { return nil }
        return try? TextureResource.generate(from: image,
                                             withName: "dreamspace-sky",
                                             options: .init(semantic: .color))
    }

    private static func makeImage() -> CGImage? {
        let size = CGSize(width: 1024, height: 512)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // Base, por si el gradiente no se puede crear.
            UIColor(red: 0.09, green: 0.11, blue: 0.20, alpha: 1).setFill()
            cg.fill(rect)

            let colors = [
                UIColor(red: 0.04, green: 0.05, blue: 0.14, alpha: 1).cgColor,
                UIColor(red: 0.10, green: 0.14, blue: 0.34, alpha: 1).cgColor,
                UIColor(red: 0.42, green: 0.62, blue: 0.82, alpha: 1).cgColor,
                UIColor(red: 0.93, green: 0.82, blue: 0.72, alpha: 1).cgColor,
                UIColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1).cgColor
            ] as CFArray

            let locations: [CGFloat] = [0, 0.36, 0.48, 0.52, 1]

            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors,
                                            locations: locations) else { return }

            cg.drawLinearGradient(gradient,
                                  start: CGPoint(x: 0, y: 0),
                                  end: CGPoint(x: 0, y: size.height),
                                  options: [])
        }

        return image.cgImage
    }
}
