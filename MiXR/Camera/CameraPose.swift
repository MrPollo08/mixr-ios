import ARKit
import CoreGraphics
import Foundation
import UIKit
import simd

/// Pose de cámara unificada, ya expresada en el marco de la **pantalla**.
///
/// Para ARKit la proyección la hace **Apple** (`ARCamera.projectPoint`), que es
/// la que usa ARSCNView para dibujar el mundo: es la única forma de que las
/// ventanas y el fondo coincidan exactamente al mover la cámara.
struct CameraPose {

    /// Cámara → mundo, con x derecha, y arriba, z hacia atrás (mira a -z).
    let transform: simd_float4x4
    let focalX: CGFloat
    let focalY: CGFloat
    let viewport: CGSize
    let imageAspect: CGFloat

    /// Cámara de ARKit (si existe) y orientación de la interfaz.
    let arkitCamera: ARCamera?
    let orientation: UIInterfaceOrientation

    struct Projection {
        let center: CGPoint
        let pointsPerMeter: CGFloat
        let depth: Float
    }

    func project(_ world: simd_float3) -> Projection? {
        guard viewport.width > 1, viewport.height > 1 else { return nil }

        let inCamera = simd_inverse(transform) * simd_float4(world, 1)
        let depth = -inCamera.z
        guard depth > Config.minDepth, depth < Config.maxDepth else { return nil }

        let pointsPerMeter = ((focalX + focalY) / 2) / CGFloat(depth)

        // Camino principal: la proyección de Apple (idéntica al fondo de ARKit).
        if let arkitCamera {
            let projected = arkitCamera.projectPoint(world,
                                                     orientation: orientation,
                                                     viewportSize: viewport)
            guard projected.x.isFinite, projected.y.isFinite else { return nil }
            return Projection(center: CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)),
                              pointsPerMeter: pointsPerMeter,
                              depth: depth)
        }

        // Respaldo (modos sin ARKit).
        guard focalX > 1, focalY > 1 else { return nil }
        let x = viewport.width / 2 + CGFloat(inCamera.x) / CGFloat(depth) * focalX
        let y = viewport.height / 2 - CGFloat(inCamera.y) / CGFloat(depth) * focalY
        return Projection(center: CGPoint(x: x, y: y),
                          pointsPerMeter: pointsPerMeter,
                          depth: depth)
    }

    // MARK: - Constructores

    /// ARKit con su cámara: proyección de Apple (6DoF).
    init(arkitCamera camera: ARCamera,
         orientation: UIInterfaceOrientation,
         viewport: CGSize,
         imageSize: CGSize) {
        let screen = ScreenOrientation.screenRotation(for: orientation)
        self.transform = camera.transform * screen
        self.focalX = CGFloat(camera.projectionMatrix.columns.0.x) * viewport.width / 2
        self.focalY = CGFloat(camera.projectionMatrix.columns.1.y) * viewport.height / 2
        self.viewport = viewport
        self.imageAspect = ScreenOrientation.displayAspect(raw: imageSize, orientation: orientation)
        self.arkitCamera = camera
        self.orientation = orientation
    }

    /// Pose de ARKit pero con una imagen de otro campo de visión.
    init(cameraTransform: simd_float4x4,
         orientation: UIInterfaceOrientation,
         viewport: CGSize,
         imageSize: CGSize,
         longFieldOfView: CGFloat) {
        let screen = ScreenOrientation.screenRotation(for: orientation)
        self.transform = cameraTransform * screen

        let display = ScreenOrientation.displaySize(raw: imageSize, orientation: orientation)
        let fill = max(viewport.width / display.width, viewport.height / display.height)
        let focalPixels = (max(imageSize.width, imageSize.height) / 2) / tan(max(longFieldOfView, 0.3) / 2)

        self.focalX = focalPixels * fill
        self.focalY = focalPixels * fill
        self.viewport = viewport
        self.imageAspect = display.width / display.height
        self.arkitCamera = nil
        self.orientation = orientation
    }

    /// Gran angular sin ARKit: rotación de CoreMotion (3DoF).
    init(rotation: simd_quatf,
         orientation: UIInterfaceOrientation,
         viewport: CGSize,
         imageSize: CGSize,
         longFieldOfView: CGFloat) {
        let screen = ScreenOrientation.screenRotation(for: orientation)
        self.transform = simd_float4x4(rotation) * screen

        let display = ScreenOrientation.displaySize(raw: imageSize, orientation: orientation)
        let fill = max(viewport.width / display.width, viewport.height / display.height)
        let focalPixels = (max(imageSize.width, imageSize.height) / 2) / tan(max(longFieldOfView, 0.3) / 2)

        self.focalX = focalPixels * fill
        self.focalY = focalPixels * fill
        self.viewport = viewport
        self.imageAspect = display.width / display.height
        self.arkitCamera = nil
        self.orientation = orientation
    }
}
