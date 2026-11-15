import ARKit
import QuartzCore
import SceneKit
import UIKit
import simd

/// Oclusión con la malla del LiDAR (`sceneReconstruction`).
///
/// La malla del cuarto se dibuja **sin color** pero escribiendo profundidad, y
/// se dibuja **antes** que el fondo 360. Resultado: la cama, la pared y los
/// muebles tapan la tormenta y por esos agujeros se ve la imagen real de la
/// cámara. Es el efecto Dreamspace: el mar alrededor y el cuarto de verdad.
final class SceneMeshOccluder {

    private struct Entry {
        let node: SCNNode
        var faces: Int
        var builtAt: TimeInterval
    }

    private let root = SCNNode()
    private var entries: [UUID: Entry] = [:]
    private var lastPrune: TimeInterval = 0

    /// Como mucho se reconstruyen dos mallas por frame (evita tirones).
    private let rebuildsPerFrame = 2
    /// Y una malla no se reconstruye más de una vez cada 0,4 s.
    private let rebuildInterval: TimeInterval = 0.4

    /// Material invisible que sólo escribe profundidad.
    private lazy var material: SCNMaterial = {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.black
        material.colorBufferWriteMask = []
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        return material
    }()

    init(parent: SCNNode) {
        root.name = "meshOccluder"
        root.renderingOrder = -1000
        parent.addChildNode(root)
    }

    /// Llamar una vez por frame con el frame de ARKit.
    func update(frame: ARFrame) {
        let now = CACurrentMediaTime()
        var alive = Set<UUID>()
        var rebuilds = 0

        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            alive.insert(mesh.identifier)

            let faces = mesh.geometry.faces.count
            let existing = entries[mesh.identifier]

            let needsBuild: Bool
            if let existing {
                needsBuild = existing.faces != faces && now - existing.builtAt > rebuildInterval
            } else {
                needsBuild = true
            }

            if needsBuild, rebuilds < rebuildsPerFrame, let geometry = makeGeometry(mesh.geometry) {
                let node = existing?.node ?? SCNNode()
                node.geometry = geometry
                node.simdTransform = mesh.transform
                if existing == nil {
                    root.addChildNode(node)
                }
                entries[mesh.identifier] = Entry(node: node, faces: faces, builtAt: now)
                rebuilds += 1
            } else if let existing {
                // La malla se movió/ajustó: seguir el ancla aunque no se
                // reconstruya la geometría (les cuesta menos que rehacerla).
                existing.node.simdTransform = mesh.transform
            }
        }

        // Limpiar mallas que ARKit ya descartó.
        guard now - lastPrune > 2 else { return }
        lastPrune = now
        for (id, entry) in entries where !alive.contains(id) {
            entry.node.removeFromParentNode()
            entries.removeValue(forKey: id)
        }
    }

    private func makeGeometry(_ mesh: ARMeshGeometry) -> SCNGeometry? {
        let vertexCount = mesh.vertices.count
        let indexCount = mesh.faces.count * 3
        guard vertexCount > 2, indexCount > 2 else { return nil }

        // Vértices (float3 empaquetados con stride).
        var points = [SCNVector3](repeating: SCNVector3Zero, count: vertexCount)
        let vertexStride = mesh.vertices.stride
        let vertexOffset = mesh.vertices.offset
        let vertexBase = mesh.vertices.buffer.contents()
        for i in 0..<vertexCount {
            let pointer = vertexBase
                .advanced(by: vertexOffset + vertexStride * i)
                .assumingMemoryBound(to: Float.self)
            points[i] = SCNVector3(pointer[0], pointer[1], pointer[2])
        }

        // Índices (uint16 o uint32 según el caso).
        var indices = [Int32](repeating: 0, count: indexCount)
        // El buffer de caras ya empieza en el primer índice: no tiene offset.
        let indexBase = mesh.faces.buffer.contents()
        if mesh.faces.bytesPerIndex == 4 {
            let pointer = indexBase.assumingMemoryBound(to: UInt32.self)
            for i in 0..<indexCount { indices[i] = Int32(pointer[i]) }
        } else {
            let pointer = indexBase.assumingMemoryBound(to: UInt16.self)
            for i in 0..<indexCount { indices[i] = Int32(pointer[i]) }
        }

        let source = SCNGeometrySource(vertices: points)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial = material
        return geometry
    }
}
