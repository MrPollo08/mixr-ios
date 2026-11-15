import SwiftUI

/// Pantalla principal: la cámara de ARKit con el monitor encima y un menú táctil.
///
/// No hay tiles ni apps: conectar la PC, fijarla en la mesa, mouse y cerrar.
struct RootView: View {
    @ObservedObject var session: XRSession

    var body: some View {
        if session.showsSetup {
            SetupView(session: session)
        } else {
            camera
        }
    }

    private var camera: some View {
        ZStack(alignment: .topLeading) {
            XRCameraView(session: session)
                .ignoresSafeArea()

            if !session.stereoEnabled {
                panel
            }

            // Volver al ajuste de los marcos, siempre accesible.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        session.openSetup()
                    } label: {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
            }
        }
        .background(Color.black)
        .onAppear { session.start() }
        .onDisappear { session.pause() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                action("Monitor PC", symbol: "display", filled: true) {
                    session.connectPC()
                }
                action("Fijar en mesa", symbol: "square.dashed", filled: false) {
                    session.snapMonitorToSurface()
                }
                action("Guardar lugar", symbol: "square.and.arrow.down", filled: false) {
                    session.savePlace()
                }
                action("Centrar", symbol: "scope", filled: false) {
                    session.centerMonitor()
                }
                action(session.framingName, symbol: "arrow.up.left.and.arrow.down.right", filled: false) {
                    session.cycleFraming()
                }
                action(session.mouseEnabled ? "Mouse ON" : "Mouse",
                       symbol: "cursorarrow",
                       filled: session.mouseEnabled) {
                    session.toggleMouse()
                }
                action("Cerrar", symbol: "xmark", filled: false) {
                    session.closeWindows()
                }
            }

            Text("IP iPhone: \(session.localAddress) · puerto 47295")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.cyan)

            Text(session.status)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.75))

            Text("Manos \(session.handCount) · pinza en el borde = mover · dos pinzas = tamaño")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(14)
    }

    private func action(_ title: String,
                        symbol: String,
                        filled: Bool,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(filled ? .black : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(filled ? Color.white : Color.white.opacity(0.16))
            )
        }
        .buttonStyle(.plain)
    }
}
