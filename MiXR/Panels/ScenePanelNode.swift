import SceneKit
import UIKit

/// Panel **3D real** en la escena de ARKit.
///
/// A diferencia de una vista de UIKit, este objeto vive en el mundo: tiene su
/// propia posición y orientación fijas, y ARKit lo renderiza con perspectiva
/// real, así que se puede rodear, ver de perfil y de espaldas.
final class ScenePanelNode: SCNNode {

    init(size: CGSize = CGSize(width: 0.95, height: 0.62)) {
        super.init()

        let plane = SCNPlane(width: size.width, height: size.height)
        plane.cornerRadius = 0.05
        plane.widthSegmentCount = 24
        plane.heightSegmentCount = 16

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = Self.panelImage(size: size)
        material.transparency = 0.97
        plane.firstMaterial = material

        geometry = plane
        name = "scenePanel"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    /// Imagen del panel: esquinas redondeadas, fondo translúcido y borde claro.
    private static func panelImage(size: CGSize) -> UIImage {
        let pixels: CGFloat = 900
        let scale = pixels / max(size.width, 0.01)
        let canvas = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: canvas)
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6),
                                    cornerRadius: canvas.height * 0.09)

            UIColor(white: 0.06, alpha: 0.62).setFill()
            path.fill()

            UIColor(white: 1.0, alpha: 0.45).setStroke()
            path.lineWidth = 9
            path.stroke()

            // Barra superior sutil
            let header = UIBezierPath(roundedRect: CGRect(x: 6, y: 6,
                                                          width: canvas.width - 12,
                                                          height: canvas.height * 0.16),
                                      cornerRadius: canvas.height * 0.09)
            UIColor(white: 1.0, alpha: 0.10).setFill()
            header.fill()
        }
    }
}
