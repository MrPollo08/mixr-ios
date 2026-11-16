import SwiftUI

/// Pantalla principal: **solo la cámara**. Nada de paneles ni menús fijos.
///
/// Toda la interfaz vive en el espacio 3D y se invoca con gestos:
/// - palma abierta de frente + pinza → menú universal
/// - pinza en el borde de una ventana → moverla
/// - pinza mantenida + mover → scroll
/// - yema del índice tocando una ventana → Direct Touch
struct RootView: View {
    @ObservedObject var session: XRSession

    var body: some View {
        XRCameraView(session: session)
            .ignoresSafeArea()
            .background(Color.black)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onAppear { session.start() }
            .onDisappear { session.pause() }
    }
}
