import ARKit
import RealityKit
import UIKit

/// Motor RealityKit del efecto Dreamspace (commit 1 de la migración).
///
/// Reemplaza al `ARSCNView` cuando `XRSession.useRealityKit` está encendido:
///
/// - **Una sola sesión de ARKit**: `ARView` recibe el mismo `ARSession` que ya
///   usa la app, así que hay una única cámara, un único tracking y las manos
///   siguen leyendo `session.currentFrame` como siempre.
/// - **Oclusión**: `environment.sceneUnderstanding.options` incluye
///   `.occlusion`, y la reconstrucción de escena se pide en la configuración
///   (`sceneReconstruction = .meshWithClassification`, en `XRSession`). Con
///   eso los objetos reales tapan lo virtual.
/// - **Cielo virtual**: una entidad (`SkyboxEntity`) pegada a la cámara.
/// - **Paneles como entidades**: `RealityPanelEntity` genera su textura y vive
///   en la escena (no es una vista de UIKit proyectada a mano).
///
/// Todo esto queda construido pero **apagado** en el commit 1: con
/// `useRealityKit = false` este objeto nunca se crea y la app sigue usando
/// SceneKit tal cual.
final class DreamspaceRenderer {

    /// La vista que se agrega al contenedor de `XRSession`.
    var view: UIView { arView }

    private let arView: ARView
    private let skybox = SkyboxEntity()
    private let panel = RealityPanelEntity()
    private var didBuildScene = false

    init() {
        arView = ARView(frame: .zero,
                        cameraMode: .ar,
                        automaticallyConfigureSession: false)
        arView.backgroundColor = .black

        // Oclusión por malla del LiDAR: lo virtual queda tapado por lo real.
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
    }

    /// Engancha la vista al `ARSession` que maneja `XRSession`.
    ///
    /// No corremos la configuración acá: la arma y la lanza `XRSession` con
    /// `sceneReconstruction` y `sceneDepth` como ya lo hace hoy.
    func attach(session: ARSession) {
        arView.session = session
        buildSceneIfNeeded()
    }

    // MARK: - Escena

    private func buildSceneIfNeeded() {
        guard !didBuildScene else { return }
        didBuildScene = true

        // Cielo: colgado de la cámara, así siempre rodea al usuario (skybox).
        let skyAnchor = AnchorEntity(.camera)
        skyAnchor.name = "skyboxAnchor"
        skyAnchor.addChild(skybox)
        arView.scene.addAnchor(skyAnchor)

        // Panel de prueba a 1,2 m delante del origen (altura de los ojos).
        // Sirve para ver la oclusión: si le pasás la mano o un objeto real
        // por delante, el panel desaparece detrás.
        let panelAnchor = AnchorEntity(world: [0, 0, -1.2])
        panelAnchor.name = "panelAnchor"
        panelAnchor.addChild(panel)
        arView.scene.addAnchor(panelAnchor)
    }
}
