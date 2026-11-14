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
            .padding(.top, 10)
            .padding(.bottom, 22)

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
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.handCount > 0 ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(session.handCount > 0 ? "\(session.handCount) mano\(session.handCount == 1 ? "" : "s")" : "sin manos")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.45)))

            Text("\(session.windowCount) ventana\(session.windowCount == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.45)))

            Spacer()

            iconButton("trash") { session.closeAllWindows() }
            iconButton("link") { session.openURLPrompt() }
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 32, height: 28)
                .background(Capsule().fill(Color.black.opacity(0.45)))
        }
        .buttonStyle(.plain)
    }

    private var hint: some View {
        Text(session.controlMode
             ? "CONTROL DEL PC · el índice mueve el cursor · pinza = clic"
             : "Pinza índice + pulgar para agarrar y mover · dos manos para escalar")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(session.controlMode ? .green : .white.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.35)))
    }

    // MARK: - Controles

    private var controlBar: some View {
        HStack(spacing: 7) {
            glassButton("display", "PC") {
                session.addPCWindow()
            }
            glassButton("play.rectangle.fill", "Video") {
                session.addVideoWindow(url: Config.sampleVideoURL)
            }
            glassButton("globe", "Web") {
                session.addWebWindow(url: Config.defaultWebURL)
            }
            glassButton("photo.on.rectangle", "Fotos") {
                session.pickVideo()
            }
            glassButton(session.handsVisible ? "hand.raised.fill" : "hand.raised.slash", "Manos") {
                session.toggleHands()
            }
            glassButton("cursorarrow", "Control", active: session.controlMode) {
                session.toggleControlMode()
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func glassButton(_ symbol: String, _ title: String,
                             active: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(active ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(active ? Color.green : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private func unsupported(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 28))
            Text("Realidad mixta no disponible")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
        }
        .foregroundColor(.white)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .padding(30)
    }
}
