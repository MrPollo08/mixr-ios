import SwiftUI

/// Ajuste de los marcos **antes** de entrar a la cámara: tamaño de cada ojo,
/// separación y altura, para que el VR box quede cómodo.
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
                        framingPicker
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
            Text("Dreamspace")
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(.white)
            Text("Ajustá los marcos del VR box y entrá a la cámara")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))

            HStack(spacing: session.vrSeparation) {
                eye
                eye
            }
            .offset(y: session.vrVertical)
        }
        .frame(height: 150)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var eye: some View {
        RoundedRectangle(cornerRadius: 54 * session.vrScale, style: .continuous)
            .fill(Color.white.opacity(0.14))
            .frame(width: 108 * session.vrScale * 1.9,
                   height: 108 * session.vrScale * 1.9)
            .overlay(
                RoundedRectangle(cornerRadius: 54 * session.vrScale, style: .continuous)
                    .stroke(accent.opacity(0.8), lineWidth: 2)
            )
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

    private var framingPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Campo de visión")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))

            HStack(spacing: 8) {
                framing("Normal", 0)
                framing("Amplia", 1)
                framing("Completa", 2)
            }
        }
    }

    private func framing(_ title: String, _ index: Int) -> some View {
        Button {
            session.framing = index
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(session.framing == index ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(session.framing == index ? Color.white : Color.white.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
    }

    private var vrToggle: some View {
        Toggle(isOn: $session.stereoEnabled) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Modo VR box")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("Dos mitades, una por ojo")
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
            Text("Empezar")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
    }

    private func slider(_ title: String,
                        value: Binding<CGFloat>,
                        range: ClosedRange<CGFloat>,
                        label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
                Spacer()
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(accent)
            }
            Slider(value: value, in: range)
                .tint(accent)
        }
    }
}
