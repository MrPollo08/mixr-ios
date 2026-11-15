import SwiftUI

/// HUD mínimo: la app se maneja con el menú flotante y las manos.
struct RootView: View {
    @ObservedObject var session: XRSession

    var body: some View {
        ZStack(alignment: .bottom) {
            XRCameraView(session: session)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    chip("\(session.handCount)",
                         color: session.handCount > 0 ? .green : .orange,
                         symbol: "hand.raised.fill")

                    chip(session.cameraMode.label, color: .cyan, symbol: "camera.viewfinder")

                    if session.controlMode {
                        chip("Mouse PC", color: .green, symbol: "cursorarrow")
                    }

                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer(minLength: 0)
                    Text(session.debugText)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
                .padding(.bottom, 4)

                Text(hintText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(session.controlMode ? .green : .white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let message = session.unsupportedMessage {
                unsupported(message)
            }
        }
        .background(Color.black)
        .onAppear { session.start() }
        .onDisappear { session.pause() }
    }

    private func chip(_ text: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private var hintText: String {
        if session.controlMode {
            return "El índice mueve el cursor del PC · pinza = clic · apuntá al menú para salir"
        }
        return "Pinza un tile · doble pinza al aire = menú · borde = estirar"
    }

    private func unsupported(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 26))
            Text("No se pudo abrir la cámara")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
        }
        .foregroundColor(.white)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .padding(30)
    }
}
