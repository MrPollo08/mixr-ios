import SwiftUI

/// Pantalla de ajuste **antes** de abrir la cámara: acá se calibra cómo se ve
/// el marco de las gafas VR (tamaño de cada ojo, separación y altura).
///
/// El botón para encender la cámara queda **fijo abajo**: en horizontal la
/// pantalla es baja y si no, se salía de vista.
struct SetupView: View {
    @ObservedObject var session: XRSession

    private let accent = Color(red: 0.55, green: 0.49, blue: 1.0)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        header
                        preview
                        controls
                        vrToggle
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                }

                startButton
            }
            .padding(.bottom, 12)
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("MiXR")
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(.white)
            Text("Ajustá el marco de las gafas y encendé la cámara")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            slider("Tamaño por ojo", value: $session.vrScale, range: 0.32...0.60,
                   label: "\(Int(session.vrScale * 100))%")
            slider("Separación", value: $session.vrSeparation, range: 0...90,
                   label: "\(Int(session.vrSeparation)) pt")
            slider("Altura", value: $session.vrVertical, range: -90...90,
                   label: "\(Int(session.vrVertical)) pt")
        }
    }

    private var vrToggle: some View {
        Toggle(isOn: $session.stereoEnabled) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Modo VR (una imagen por ojo)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(session.stereoEnabled ? "Pantalla partida en dos" : "Pantalla normal")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: accent))
    }

    private var startButton: some View {
        Button {
            session.startCamera()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .bold))
                Text("Encender cámara")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
    }

    /// Dibujo del marco: muestra cómo va a quedar cada ojo.
    private var preview: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let eyeWidth = width / 2
            let frameWidth = width * session.vrScale
            let frameHeight = height * session.vrScale

            ZStack {
                Color(white: 0.04)

                HStack(spacing: 0) {
                    eyeOutline(width: eyeWidth, height: height, frameWidth: frameWidth,
                               frameHeight: frameHeight, shift: -session.vrSeparation / 2)
                    eyeOutline(width: eyeWidth, height: height, frameWidth: frameWidth,
                               frameHeight: frameHeight, shift: session.vrSeparation / 2)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 1)
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private func eyeOutline(width: CGFloat, height: CGFloat,
                            frameWidth: CGFloat, frameHeight: CGFloat,
                            shift: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                .frame(width: width, height: height)

            RoundedRectangle(cornerRadius: 4)
                .stroke(accent, lineWidth: 2)
                .frame(width: frameWidth, height: frameHeight)
                .offset(x: shift, y: session.vrVertical * 0.25)
        }
        .frame(width: width, height: height)
    }

    private func slider(_ title: String, value: Binding<CGFloat>,
                        range: ClosedRange<CGFloat>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
            Slider(value: value, in: range)
                .tint(accent)
        }
    }
}
