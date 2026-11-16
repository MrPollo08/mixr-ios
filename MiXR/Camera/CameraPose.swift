import ARKit
import CoreGraphics
import Foundation
import UIKit
import simd

/// Pose de cámara 6DoF + Giroscopio unificada, expresada en el marco de la **pantalla**.
///
/// Para la vista monocular usa `ARCamera.projectPoint` / intrínsecos reales;
/// para estereoscopía VR Box genera las poses de ojo izquierdo y derecho (`±IPD/2`)
/// y desproyecta puntos 2D + profundidad LiDAR al espacio 3D real (metros).
struct CameraPose {

    /// Cámara → mundo, con x derecha, y arriba, z hacia atrás (mira a -z).
    let transform: simd_float4x4
    let focalX: CGFloat
    let focalY: CGFloat
    let viewport: CGSize
    let imageAspect: CGFloat

    /// Cámara de ARKit (si existe y no es un ojo desplazado en VR) y orientación.
    let arkitCamera: ARCamera?
    let orientation: UIInterfaceOrientation

    /// ARKit viene con tracking limitado (poca luz/textura): activa suavizado extra.
    var trackingLimited = false

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

        // Camino principal monocular: proyección nativa de ARCamera.
        if let arkitCamera {
            let projected = arkitCamera.projectPoint(world,
                                                     orientation: orientation,
                                                     viewportSize: viewport)
            guard projected.x.isFinite, projected.y.isFinite else { return nil }
            return Projection(center: CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)),
                              pointsPerMeter: pointsPerMeter,
                              depth: depth)
        }

        // Proyección pinhole (usada en ojos desplazados por IPD en VR Box o 3DoF).
        guard focalX > 1, focalY > 1 else { return nil }
        let x = viewport.width / 2 + CGFloat(inCamera.x) / CGFloat(depth) * focalX
        let y = viewport.height / 2 - CGFloat(inCamera.y) / CGFloat(depth) * focalY
        guard x.isFinite, y.isFinite else { return nil }
        return Projection(center: CGPoint(x: x, y: y),
                          pointsPerMeter: pointsPerMeter,
                          depth: depth)
    }

    /// Desproyecta un punto 2D del viewport con profundidad real `depth` (metros LiDAR)
    /// al espacio 3D local de la cámara (`x` derecha, `y` arriba, `-z` adelante).
    func unprojectToCamera(screenPoint: CGPoint, depth: Float) -> simd_float3 {
        let safeDepth = max(depth, 0.08)
        let fx = Float(max(focalX, 200))
        let fy = Float(max(focalY, 200))
        let cx = Float(viewport.width * 0.5)
        let cy = Float(viewport.height * 0.5)

        let xCam = ((Float(screenPoint.x) - cx) / fx) * safeDepth
        let yCam = ((cy - Float(screenPoint.y)) / fy) * safeDepth
        let zCam = -safeDepth
        return simd_float3(xCam, yCam, zCam)
    }

    /// Pasa un punto 3D del marco de la cámara al mundo de ARKit.
    func cameraToWorld(_ cameraPoint: simd_float3) -> simd_float3 {
        let world4 = transform * simd_float4(cameraPoint.x, cameraPoint.y, cameraPoint.z, 1.0)
        return simd_float3(world4.x, world4.y, world4.z)
    }

    /// Pasa un punto 3D del mundo de ARKit al marco local de la cámara.
    func worldToCamera(_ worldPoint: simd_float3) -> simd_float3 {
        let cam4 = simd_inverse(transform) * simd_float4(worldPoint.x, worldPoint.y, worldPoint.z, 1.0)
        return simd_float3(cam4.x, cam4.y, cam4.z)
    }

    /// Genera la pose de un ojo en modo VR Box desplazando sobre el eje X local (`±IPD/2`).
    func eyePose(horizontalOffsetMeters: Float) -> CameraPose {
        var matrix = transform
        let right = simd_float3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
        let shift = right * horizontalOffsetMeters
        matrix.columns.3 = simd_float4(matrix.columns.3.x + shift.x,
                                       matrix.columns.3.y + shift.y,
                                       matrix.columns.3.z + shift.z, 1)
        var result = CameraPose(transform: matrix, focalX: focalX, focalY: focalY,
                                viewport: viewport, imageAspect: imageAspect,
                                arkitCamera: nil, orientation: orientation)
        result.trackingLimited = trackingLimited
        return result
    }

    /// Copia con la cámara corrida a lo largo de su eje de visión (+ = adelante).
    func moved(alongView meters: Float) -> CameraPose {
        var matrix = transform
        let backward = simd_float3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        let shift = backward * -meters
        matrix.columns.3 = simd_float4(matrix.columns.3.x + shift.x,
                                       matrix.columns.3.y + shift.y,
                                       matrix.columns.3.z + shift.z, 1)
        var result = CameraPose(transform: matrix, focalX: focalX, focalY: focalY,
                                viewport: viewport, imageAspect: imageAspect,
                                arkitCamera: arkitCamera, orientation: orientation)
        result.trackingLimited = trackingLimited
        return result
    }

    private init(transform: simd_float4x4, focalX: CGFloat, focalY: CGFloat,
                 viewport: CGSize, imageAspect: CGFloat,
                 arkitCamera: ARCamera?, orientation: UIInterfaceOrientation) {
        self.transform = transform
        self.focalX = focalX
        self.focalY = focalY
        self.viewport = viewport
        self.imageAspect = imageAspect
        self.arkitCamera = arkitCamera
        self.orientation = orientation
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

    /// ARKit + Giroscopio fusionado (`HybridHeadTracker`).
    init(arkitCamera camera: ARCamera,
         fusedDeviceTransform: simd_float4x4,
         orientation: UIInterfaceOrientation,
         viewport: CGSize,
         imageSize: CGSize) {
        let screen = ScreenOrientation.screenRotation(for: orientation)
        self.transform = fusedDeviceTransform * screen
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
