import RealityKit
import UIKit

/// Panel de prueba del efecto Dreamspace.
///
/// Es el molde de las ventanas de la app: una entidad con una textura generada
/// en runtime. A diferencia de las vistas de UIKit (que se proyectan a mano en
/// cada frame), este objeto vive en la escena de RealityKit: tiene posición y
/// orientación propias, el renderer le aplica perspectiva y la malla del LiDAR
/// lo puede tapar.
class RealityPanelEntity: Entity {

    init(width: Float, height: Float, title: String, subtitle: String) {
        super.init()
        build(width: width, height: height, title: title, subtitle: subtitle)
    }

    /// RealityKit exige el init sin argumentos (`Entity.init()` es `required`):
    /// es el panel por defecto que usa el commit 1 para probar la oclusión.
    required init() {
        super.init()
        build(width: 0.9,
              height: 0.55,
              title: "Panel de prueba",
              subtitle: "RealityKit · Dreamspace")
    }

    private func build(width: Float, height: Float, title: String, subtitle: String) {
        name = "realityPanel"

        let mesh = MeshResource.generatePlane(width: width,
                                             height: height,
                                             cornerRadius: 0.035)

        var material = UnlitMaterial()
        if let image = RealityPanelEntity.makeImage(width: width,
                                                    height: height,
                                                    title: title,
                                                    subtitle: subtitle),
           let texture = try? TextureResource.generate(from: image,
                                                       withName: "dreamspace-panel",
                                                       options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            material.color = .init(tint: UIColor(white: 0.10, alpha: 1), texture: nil)
        }
        // El panel se puede mirar de costado y de atrás sin desaparecer.

        addChild(ModelEntity(mesh: mesh, materials: [material]))
    }

    // MARK: - Textura

    /// Tarjeta oscura con borde claro y dos líneas de texto. Se dibuja con
    /// UIKit porque es lo mismo que hace `ScenePanelNode` en SceneKit.
    private static func makeImage(width: Float,
                                  height: Float,
                                  title: String,
                                  subtitle: String) -> CGImage? {
        let pixels: CGFloat = 900
        let aspect = CGFloat(height / max(width, 0.01))
        let canvas = CGSize(width: pixels, height: pixels * aspect)
        let padding = canvas.height * 0.11

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let image = renderer.image { context in
            let rect = CGRect(origin: .zero, size: canvas)
            let cg = context.cgContext

            let colors = [
                UIColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1).cgColor,
                UIColor(red: 0.10, green: 0.13, blue: 0.22, alpha: 1).cgColor
            ] as CFArray

            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: [0, 1]) {
                cg.drawLinearGradient(gradient,
                                      start: CGPoint(x: 0, y: 0),
                                      end: CGPoint(x: 0, y: canvas.height),
                                      options: [])
            } else {
                UIColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 1).setFill()
                cg.fill(rect)
            }

            // Borde
            let border = UIBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5),
                                      cornerRadius: canvas.height * 0.07)
            UIColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 0.55).setStroke()
            border.lineWidth = 8
            border.stroke()

            // Título y subtítulo
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: canvas.height * 0.16, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: canvas.height * 0.075, weight: .regular),
                .foregroundColor: UIColor(red: 0.62, green: 0.86, blue: 1.0, alpha: 1)
            ]

            let titleRect = CGRect(x: padding,
                                   y: canvas.height * 0.40,
                                   width: canvas.width - padding * 2,
                                   height: canvas.height * 0.24)
            (title as NSString).draw(in: titleRect, withAttributes: titleAttributes)

            let subtitleRect = CGRect(x: padding,
                                      y: canvas.height * 0.64,
                                      width: canvas.width - padding * 2,
                                      height: canvas.height * 0.16)
            (subtitle as NSString).draw(in: subtitleRect, withAttributes: subtitleAttributes)
        }

        return image.cgImage
    }
}
