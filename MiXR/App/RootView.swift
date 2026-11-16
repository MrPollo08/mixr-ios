import SwiftUI

/// Pantalla principal: la cámara, el readout de diagnóstico y un panel de captura.
///
/// El panel de captura existe porque los botones ocultos (mando/volumen) no funcionan
/// en todos los setups: acá se toca y listo. Cuando el modelo esté entrenado se saca.
struct RootView: View {
    @ObservedObject var session: XRSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            XRCameraView(session: session)
                .ignoresSafeArea()

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

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if session.showsCapturePanel {
                        capturePanel
                    }
                    Spacer()
                    captureToggle
                }
                .padding(14)
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { session.start() }
        .onDisappear { session.pause() }
    }

    // MARK: - Panel de captura

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("CAPTURA DE GESTOS")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)

            Text(session.captureStatus.isEmpty ? "CAP —" : session.captureStatus)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.cyan)

            if !session.captureCountsText.isEmpty {
                Text(session.captureCountsText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
            }

            Button {
                session.toggleCaptureMode()
            } label: {
                Text(session.captureMode ? "Salir de captura" : "Entrar en captura")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)

            if session.captureMode {
                Button {
                    if session.guidedText.isEmpty || session.guidedText.hasPrefix("Listo") {
                        session.startGuidedCapture()
                    } else {
                        session.cancelGuidedCapture()
                    }
                } label: {
                    Text(session.guidedText.isEmpty || session.guidedText.hasPrefix("Listo")
                         ? "GRABAR TODOS (90 s)"
                         : "Cancelar")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(session.guidedText.hasPrefix("GRABANDO")
                                                   ? Color.yellow : Color.white))
                }
                .buttonStyle(.plain)

                if !session.guidedText.isEmpty {
                    Text(session.guidedText)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow)
                }

                HStack(spacing: 8) {
                    Button {
                        session.toggleRecording()
                    } label: {
                        Text(recordingTitle)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(recordingColor))
                    }
                    .buttonStyle(.plain)

                    Button {
                        session.nextGestureLabel()
                    } label: {
                        Text("Siguiente gesto")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    session.clearCaptureDataset()
                } label: {
                    Text("Borrar todo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)

                if !session.captureURLText.isEmpty {
                    Text(session.captureURLText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var recordingTitle: String {
        session.captureStatus.hasPrefix("CAP") && session.captureStatus.contains("REC")
            ? "Parar"
            : "Grabar"
    }

    private var recordingColor: Color {
        session.captureStatus.contains("REC") ? Color.red : Color.green.opacity(0.85)
    }

    private var captureToggle: some View {
        Button {
            session.showsCapturePanel.toggle()
        } label: {
            Image(systemName: "record.circle")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(12)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
    }
}
