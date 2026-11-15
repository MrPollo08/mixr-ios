import SwiftUI

/// Pantalla de ajuste **antes** de abrir la cámara: acá se calibra cómo se ve
/// el marco de las gafas VR (tamaño de cada ojo, separación y altura).
struct SetupView: View {
    @ObservedObject var session: XRSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("MiXR")
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundColor(.white)
                    Text("Ajustá las gafas antes de encender la cámara")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.top, 8)

                preview

                VStack(spacing: 12) {
                    slider("Tamaño por ojo", value: $session.vrScale, range: 0.32...0.60,
                           label: "\(Int(session.vrScale * 100))%")
                    slider("Separación", value: $session.vrSeparation, range: 0...80,
                           label: "\(Int(session.vrSeparation)) pt")
                    slider("Altura", value: $session.vrVertical, range: -90...90,
                           label: "\(Int(session.vrVertical)) pt")
                }
                .padding(.horizontal, 18)

                Toggle(isOn: $session.stereoEnabled) {
                    Text("Modo VR (una imagen por ojo)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.55, green: 0.49, blue: 1.0)))
                .padding(.horizontal, 18)

                Button {
                    session.startCamera()
                } label: {
                    Text("Encender cámara")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white)
                        )
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
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
                Color.black

                HStack(spacing: 0) {
                    eyeOutline(width: eyeWidth, height: height, frameWidth: frameWidth,
                               frameHeight: frameHeight, shift: -session.vrSeparation / 2)
                    eyeOutline(width: eyeWidth, height: height, frameWidth: frameWidth,
                               frameHeight: frameHeight, shift: session.vrSeparation / 2)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 1)
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 18)
    }

    private func eyeOutline(width: CGFloat, height: CGFloat,
                            frameWidth: CGFloat, frameHeight: CGFloat,
                            shift: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .frame(width: width, height: height)

            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(red: 0.55, green: 0.49, blue: 1.0), lineWidth: 2)
                .frame(width: frameWidth, height: frameHeight)
                .offset(x: shift, y: session.vrVertical)
        }
        .frame(width: width, height: height)
    }

    private func slider(_ title: String, value: Binding<CGFloat>,
                        range: ClosedRange<CGFloat>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
            Slider(value: value, in: range)
                .tint(Color(red: 0.55, green: 0.49, blue: 1.0))
        }
    }
}
