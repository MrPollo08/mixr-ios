import SwiftUI

struct RootView: View {
    @ObservedObject var session: XRSession

    var body: some View {
        ZStack(alignment: .bottom) {
            XRCameraView(session: session)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                topBar
                Spacer(minLength: 0)
                hint
                controlBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)

            if let message = session.unsupportedMessage {
                unsupported(message)
            }
        }
        .background(Color.black)
        .onAppear { session.start() }
        .onDisappear { session.pause() }
    }

    // MARK: - Barra superior

    private var topBar: some View {
        HStack(spacing: 7) {
            chip("\(session.handCount)", color: session.handCount > 0 ? .green : .orange,
                 symbol: "hand.raised.fill")

            chip("\(session.windowCount)", color: .white.opacity(0.75), symbol: "square.on.square")

            Button { session.toggleCameraMode() } label: {
                chipLabel(session.cameraMode.label,
                          color: session.cameraMode == .ultraWide ? .cyan : .white.opacity(0.75))
            }
            .buttonStyle(.plain)

            Button { session.toggleOcclusion() } label: {
                chipLabel("Oclusión",
                          color: session.occlusionEnabled ? .cyan : .white.opacity(0.45))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            Button { session.recenterView() } label: {
                icon("scope")
            }
            .buttonStyle(.plain)

            Button { session.closeAllWindows() } label: {
                icon("trash")
            }
            .buttonStyle(.plain)

            Button { session.openURLPrompt() } label: {
                icon("link")
            }
            .buttonStyle(.plain)
        }
    }

    private func chipLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.5)))
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

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 32, height: 28)
            .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private var hint: some View {
        Text(hintText)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(session.controlMode ? .green : .white.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.35)))
    }

    private var hintText: String {
        if session.controlMode {
            return "CONTROL DEL PC · el índice mueve el cursor · pinza = clic"
        }
        if session.cameraMode == .ultraWide {
            return "0.5× gran angular · pinza para agarrar · dos manos para escalar"
        }
        return "1× con 6DoF · pinza para agarrar · dos manos para escalar"
    }

    // MARK: - Controles

    private var controlBar: some View {
        HStack(spacing: 7) {
            glassButton("display", "PC") { session.addPCWindow() }
            glassButton("play.rectangle.fill", "Video") {
                session.addVideoWindow(url: Config.sampleVideoURL)
            }
            glassButton("globe", "Web") { session.addWebWindow(url: Config.defaultWebURL) }
            glassButton("photo.on.rectangle", "Fotos") { session.pickVideo() }
            glassButton(session.handsVisible ? "hand.raised.fill" : "hand.raised.slash", "Manos") {
                session.toggleHands()
            }
            glassButton("cursorarrow", "Control", active: session.controlMode) {
                session.toggleControlMode()
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func glassButton(_ symbol: String, _ title: String,
                             active: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(active ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? Color.green : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
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
