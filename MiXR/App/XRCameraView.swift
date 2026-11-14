import SwiftUI
import UIKit

/// Envuelve la vista de UIKit donde vive ARKit + las ventanas flotantes.
struct XRCameraView: UIViewRepresentable {
    let session: XRSession

    func makeUIView(context: Context) -> UIView {
        session.containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
