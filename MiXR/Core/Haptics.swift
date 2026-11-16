import UIKit

/// Respuesta háptica mínima para los eventos de la interfaz espacial.
///
/// En una caja VR el tacto es el único canal que no compite con la vista: sentir el
/// "clic" cuando agarrás algo ancla la acción al cuerpo y hace que la interfaz se
/// sienta física en vez de flotante.
enum Haptics {

    private static let impact = UIImpactFeedbackGenerator(style: .medium)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let selection = UISelectionFeedbackGenerator()

    static func prepare() {
        impact.prepare()
        light.prepare()
        selection.prepare()
    }

    /// Empezó un agarre.
    static func grab() {
        impact.impactOccurred(intensity: 0.85)
    }

    /// Soltó.
    static func release() {
        light.impactOccurred(intensity: 0.55)
    }

    /// Clic / selección.
    static func tap() {
        selection.selectionChanged()
    }
}
