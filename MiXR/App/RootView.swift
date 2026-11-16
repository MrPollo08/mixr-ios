import SwiftUI

/// Pantalla principal: **solo la cámara**. Nada de paneles ni menús fijos.
///
/// Toda la interfaz vive en el espacio 3D y se invoca con gestos:
/// - doble toque → reenfocar y congelar
/// - triple toque → mano fantasma ↔ malla sintética
/// - pinza en el borde de una ventana → moverla
/// - pinza mantenida + mover → scroll
/// - yema del índice tocando una ventana → Direct Touch
struct RootView: View {
    @ObservedObject var session: XRSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            XRCameraView(session: session)
                .ignoresSafeArea()

            // Diagnóstico temporal: permite ver qué eslabón del pipeline falla.
            Text(session.debugText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.45))
                .cornerRadius(5)
                .padding(.leading, 18)
                .padding(.top, 10)
                .allowsHitTesting(false)
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { session.start() }
        .onDisappear { session.pause() }
    }
}
